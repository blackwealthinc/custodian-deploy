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

---

## The LICENCE catalog (our revenue) — generated, NOT uploaded

`custodian-catalog.xml` above is the **retail** catalog: what the reseller charges *their*
customers. Under Model B the reseller also pays **us** a licence, and until 2026-09-30 **no licence
plan existed anywhere** — `features/domain-email-and-go-to-market-strategy.md` §1.3 records that as
a hard blocker: *there was nothing to invoice a reseller from.*

**Two catalogs, not one:**

| Catalog | Whose tenant | Who pays whom |
|---|---|---|
| `custodian-catalog.xml` | the reseller's | their customers → them |
| `custodian-licence-catalog.xml` *(generated)* | **ours** | the reseller → **us** |

**Generate it** — never hand-edit, and never invent the base:

```bash
python3 catalog/make-licence-catalog.py --server-cost 6.00 --baseline-tokens 1 \
    > /tmp/licence-catalog.xml
```

**Validate before uploading** (Kill Bill's own validator, not a local XSD guess):

```bash
curl -s -u admin:password -H "X-Killbill-ApiKey: custodian" \
  -H "X-Killbill-ApiSecret: $KB_KILLBILL_API_SECRET" -H "X-Killbill-CreatedBy: custodian-setup" \
  -H "Content-Type: text/xml" -H "Accept: application/json" \
  -X POST --data-binary @/tmp/licence-catalog.xml \
  http://192.168.50.104:8080/1.0/kb/catalog/xml/validate
# -> http 200 = valid
```

Measured 2026-09-30: **both candidate models validate `http 200`** (server + 1 baseline token unit,
and server-only).

**What is LOCKED vs NOT** (`pricing/reseller-pricing-model.md`):

- **Locked 2026-09-28:** the margin ladder — monthly **×1.35**, quarterly **×1.40**, semi-annual
  **×1.40**, annual **×1.40**. (Semi-annual was dropped from ×1.45 so the ladder stops running
  backwards; annual stays 40 %.) This ladder IS the margin — change the pricing doc first.
- **NOT locked:** the operating base. §5 of that doc: *"server ($5–6) + token cost"* mixes a FIXED
  cost with a VARIABLE one, so the intended shape is *baseline plan + pay-as-you-go overage* — but
  **the baseline token allotment per cycle is unconfirmed.** Hence `--server-cost` and
  `--baseline-tokens` are **required with no defaults**: a guessed price must not reach the billing
  engine. This is the single input that unblocks the four plans, the Hugo pricing page, and the E2E.

**Why there is no reload plan here** — deliberately. Earlier drafts said our catalog must hold
"4 frequencies + a reload product". **Superseded:** a top-up is an arbitrary one-time amount
(min $10, no max), which no catalog plan can express. It is an **EXTERNAL CHARGE** carrying
`CUSTODIAN_TOPUP` in `itemDetails` (`kb_bridge.py run_topup`). A reload plan would create a second,
contradictory mechanism.

**⚠️ NOT uploaded.** The structure is authored and validator-proven; the *price* is a business
decision owned by Neo + his father. Uploading a guessed figure would put a wrong price in the
billing engine.

