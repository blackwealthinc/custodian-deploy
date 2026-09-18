# Custodian Kill Bill catalog

`custodian-catalog.xml` — the standalone catalog uploaded to the Kill Bill tenant
on `.104`. Defines what the **customer is charged (retail)**.

## Plans

| Plan | Retail / month | Cost budget pushed to LiteLLM |
|---|---|---|
| `basic` | $20 | $5 |
| `pro` | $59 | $20 |
| `business` | $200 | $100 |

Retail prices come from `features/killbill-integration-master-plan.md` §3
("re-priced Aug 17, 2026"). **Retail ≠ cost budget** — the margin lives between
them, and pushing retail to LiteLLM would zero the margin. Cost budgets live in
kb-bridge's `plans` table (`kb_bridge.py plan --plan-name ... --max-budget ...`),
not in this file.

Plan names are deliberately identical to kb-bridge's plan names so the mapping
is legible when reading either side.

## Shape

All three plans: `MONTHLY`, `IN_ADVANCE`, `EVERGREEN`, single product
`custodian` (category `BASE`), price list `DEFAULT`. No trial phase, so that
subscribing immediately generates a real chargeable invoice — which is what the
end-to-end payment test needs.

## Applying it

Validate **before** uploading — Kill Bill's own validator, not a local XSD check:

```bash
# NOTE: the endpoint consumes text/xml, NOT application/xml.
curl -s -u admin:password \
  -H "X-Killbill-ApiKey: custodian" -H "X-Killbill-ApiSecret: $KB_KILLBILL_API_SECRET" \
  -H "X-Killbill-CreatedBy: custodian-setup" \
  -H "Content-Type: text/xml" -H "Accept: application/json" \
  -X POST --data-binary @custodian-catalog.xml \
  http://192.168.50.104:8080/1.0/kb/catalog/xml/validate
# -> {"catalogValidationErrors":[]}
```

Then swap `/xml/validate` for `/xml` to upload (expect `201`).

## Verifying it took

```bash
curl -s ... http://192.168.50.104:8080/1.0/kb/catalog/versions
#   -> ["2026-01-01T00:00:00.000Z"]

curl -s ... http://192.168.50.104:8080/1.0/kb/catalog/availableBasePlans
#   -> basic $20 / pro $59 / business $200, MONTHLY, DEFAULT
```

Measured 2026-09-18: both returned exactly the above.

## Notes

- A catalog is a **versioned** object keyed by `effectiveDate`; Kill Bill keeps old
  versions and applies the one in force at a given date.
- `CATALOG` is a **multi-value** tenant key (`CATALOG(false)` in `TenantKV`),
  unlike `PUSH_NOTIFICATION_CB(true)` — that is how catalog versioning is stored.
- `DELETE /1.0/kb/catalog` exists if a bad upload needs to be rolled back.
