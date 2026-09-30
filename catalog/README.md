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

### ✅ Use the script, not the raw curl

The manual commands above are shown for understanding only. **The supported path is
`catalog/upload-catalog.sh`**, because the manual path uploads the file **verbatim** — and the file's
`effectiveDate` is `2026-01-01`, which is *in the past* and therefore reproduces bug #167 on any
tenant created after that date (i.e. every reseller tenant). The script stamps the date instead:

```bash
# Run on VM205 -- the only host holding the KB tenant plaintext secret.
# Export the tenant values from /opt/kb-bridge/kb-bridge.env first, then:
./catalog/upload-catalog.sh --kb-url http://192.168.50.104:8080 --dry-run   # validate only
./catalog/upload-catalog.sh --kb-url http://192.168.50.104:8080            # upload + verify
```

It refuses to upload unless **all** of these hold, so it cannot repeat the mistakes already made once:

* the stamped XML is **well-formed** (strict `expat` parse — a `200` is not a parse check)
* the validator's **body** has an **empty** `catalogValidationErrors` list (**HTTP 200 with errors in
  the body means INVALID**)
* the upload returns `201`
* `availableBasePlans` is **non-empty** afterwards — i.e. the stamped date actually outranked the
  tenant's auto-created empty default on *that* tenant

Run it from **VM205** (the only host holding the KB tenant plaintext secret).

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
  **Consequence: a tenant normally holds TWO active `CATALOG` rows** — the empty
  `DEFAULT` template every tenant gets at creation, plus yours. That is not a bug;
  see the effectiveDate rule below.
- ⚠️ **DO NOT use `DELETE /1.0/kb/catalog` to roll back a bad upload.** It deletes
  **ALL** versions and then re-creates a *fresh empty default* — so it does not
  restore the previous catalogue, it destroys the current one and leaves a naive
  "repair" looking like a fix. Correct rollback: upload a **newer** version with the
  corrected content (versions are immutable and ordered by `effectiveDate`), or
  deactivate the offending `tenant_kvs` row and broadcast the change.

### ⚠️ The effectiveDate rule (this caused bug #167)

`POST /1.0/kb/tenants` ends with `createDefaultEmptyCatalog(...)`, so **every new
tenant is born with an empty `DEFAULT` catalogue dated `createdDate − 1 day`**.
Kill Bill then has two orderings that must agree:

| Mechanism | Orders by | Picks |
|---|---|---|
| `getCurrentVersion()` (unfiltered paths) | `effectiveDate` | the **greatest** date |
| `updateTenantLastKeyValue()` | `record_id` | the **highest** record id |

The empty template is skipped wherever `filterTemplateCatalog=true` — which is every
billing/entitlement path. **One path passes `false`: `DefaultCatalogUserApi:195`
(the Simple Plan API).** There the ordering matters.

> **Rule: a real catalogue must carry an `effectiveDate` LATER than the tenant's
> auto-created default.**

`custodian-catalog.xml` is dated **`2026-01-01`** — i.e. in the past. Uploaded to a
tenant created after that date it sorts *before* the auto-default, and the two
orderings disagree. On tenant 3 the condition was neutralised by deactivating the
empty row (bug #167, 2026-09-30). **A static date cannot satisfy the rule forever**,
so the retail catalogue must be re-stamped at upload time, not read verbatim.

---

## The LICENCE catalog (our revenue) — GENERATED, INSTALLED, AND BILLING

> **Status 2026-09-30:** live on **tenant 4 (`custodian-licence`)**, validator-clean,
> 4 plans available, and **proven by a real invoice** (#22, $8.10, RECURRING
> `licence-monthly` 2026-09-30 → 2026-10-30). The section below that read
> *"generated, NOT uploaded"* is superseded — see §5c of
> `research/phase3-plan-2026-09-30.md`.

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
python3 catalog/make-licence-catalog.py --server-cost 6.00 --baseline-tokens 0 \
    --effective "$(date -u +%Y-%m-%dT00:00:00+00:00)" \
    > /tmp/licence-catalog.xml
```

**Validate before uploading** (Kill Bill's own validator, not a local XSD guess):

```bash
curl -s -u admin:password -H "X-Killbill-ApiKey: custodian" \
  -H "X-Killbill-ApiSecret: $KB_KILLBILL_API_SECRET" -H "X-Killbill-CreatedBy: custodian-setup" \
  -H "Content-Type: text/xml" -H "Accept: application/json" \
  -X POST --data-binary @/tmp/licence-catalog.xml \
  http://192.168.50.104:8080/1.0/kb/catalog/xml/validate
# -> {"catalogValidationErrors":[]}      <-- EMPTY LIST = valid
```

> ⚠️ **The validator answers HTTP 200 even when the catalogue is INVALID.** Errors
> arrive in the response **body** (`catalogValidationErrors`). Two defects reached a
> 200-with-errors state on 2026-09-30: `SEMI_ANNUAL` is **not** a `BillingPeriod`
> value (semi-annual is `BIANNUAL`), and XML comments may not contain a **double
> hyphen**. **Read the body, not the status code.** Cross-check with a strict parser
> (`xml.parsers.expat`) before uploading.

Measured 2026-09-30: **both candidate models validate `http 200`** (server + 1 baseline token unit,
and server-only).

**What is LOCKED vs NOT** (`pricing/reseller-pricing-model.md`):

- **Locked 2026-09-28:** the margin ladder — monthly **×1.35**, quarterly **×1.40**, semi-annual
  **×1.40**, annual **×1.40**. (Semi-annual was dropped from ×1.45 so the ladder stops running
  backwards; annual stays 40 %.) This ladder IS the margin — change the pricing doc first.
- **RESOLVED 2026-09-30 — server-only; all tokens arrive as reloads.** The base is
  `--server-cost 6.00 --baseline-tokens 0`. This is **forced by our own arithmetic,
  not guessed**: the licence ladder is ×1.35–1.40 while the reload markup is ×1.15, so
  a bundled token allowance would sell tokens *dearer* than buying them on demand and
  would be strictly dominated. It is also the model the **shipped** Phase 2 code
  enforces — one token-funding path, the external charge credited `paid ÷ 1.15`
  (proven live, event 372). `$6.00` is the top of our documented "$5–6 (server)"
  range, i.e. the conservative side. **One command to change; the catalogue is
  versioned, so changing it rewrites nothing.**
- **The margin** lives in the licence fee and the 15 % reload fee — **never in the
  meter**. The meter must equal **cost**.

**Why there is no reload plan here** — deliberately. Earlier drafts said our catalog must hold
"4 frequencies + a reload product". **Superseded:** a top-up is an arbitrary one-time amount
(min $10, no max), which no catalog plan can express. It is an **EXTERNAL CHARGE** carrying
`CUSTODIAN_TOPUP` in `itemDetails` (`kb_bridge.py run_topup`). A reload plan would create a second,
contradictory mechanism.

**✅ INSTALLED 2026-09-30** on tenant 4 (`custodian-licence`) — see the status box at
the top of this section. The earlier warning here (*"NOT uploaded … uploading a guessed
figure would put a wrong price in the billing engine"*) is **superseded**: the base is
now resolved server-side and the upload was proven with a real invoice, not asserted.

**One tenant, one catalogue name.** `uploadCatalog` validates and **throws** on a
catalogue-name mismatch, so the licence catalogue **cannot** live beside the retail one.
Model B therefore genuinely needs **two tenants** — `custodian-demo` (retail, theirs) and
`custodian-licence` (licence, ours) — exactly as
`features/domain-email-and-go-to-market-strategy.md` §1.3 says.

