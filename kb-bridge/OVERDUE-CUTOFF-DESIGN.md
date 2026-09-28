# Overdue → budget cut-off — design + source-verified facts

**Status:** ✅ **LADDER ACTIVATED 2026-09-24 12:40:09 UTC** — `POST /1.0/kb/overdue → http=201`, tenant `custodian`, by `custodian-deploy` · design complete, source-verified
**Created:** 2026-09-24 · **Verified against:** `killbill-0.24.21` source, `litellm` source, live `.104`
**Requirement:** *"cut services when payment is missing — from both debit/credit AND crypto"* (Neo, hard gate)

---

## 1. THE FIVE THINGS THE RESEARCH CORRECTED

All five came from reading the actual source at tag `killbill-0.24.21` / current `litellm`, not from the earlier research note.

| # | Earlier belief | **Verified truth** | Consequence |
|---|---|---|---|
| 1 | *"JSON config supports only the time condition; XML supports more"* | **Wrong.** `OverdueConditionJson` accepts **six** fields: `timeSinceEarliestUnpaidInvoiceEqualsOrExceeds`, `numberOfUnpaidInvoicesEqualsOrExceeds`, `totalUnpaidInvoiceBalanceEqualsOrExceeds`, `controlTagInclusion`, `controlTagExclusion`, `responseForLastFailedPayment` | XML is **not** required for richer conditions. Either format works. |
| 2 | *"Anchor the ladder to the invoice **due date** for crypto"* | **Impossible.** `BillingStateCalculator`: `dateOfEarliestUnpaidInvoice = invoice.getInvoiceDate()` — the timer counts from the **invoice date**, and `dueDate` is never consulted | For crypto (unpaid from creation) the clock starts immediately. The window can only be **widened**, or split per-rail via **tags**. |
| 3 | *"(test immediately)"* | **Not possible by time.** `DefaultDuration.toJodaPeriod()` allows only **DAYS / WEEKS / MONTHS / YEARS / UNLIMITED** | The fastest time threshold is **1 DAY**. Instant tests must use `numberOfUnpaidInvoicesEqualsOrExceeds`. |
| 4 | *"max_budget=0 might mean unlimited"* | **It blocks.** Three enforcement paths use `math.isfinite(max_budget) and spend >= max_budget`. `0` is finite and `spend >= 0` is always true. `/budget/update` **accepts 0** (validation rejects only `< 0`). `None` is the "unlimited" value | ✅ The cut-off mechanism is **safe**. |
| 5 | *"the spend-reset needs custom code"* | **Native.** `/budget/update` accepts **`budget_duration`** and LiteLLM resets the window itself. The bridge **already** supports it via `KB_BUDGET_DURATION` (`kb_bridge.py:132,350`) — it is simply **empty** | **Bug #156 is a one-line env fix**, and it doubles as the cut-off's self-healing restore. |

---

## 2. THE LADDER (as written to `.104`)

`/opt/killbill/overdue-custodian.xml` · **3 states · worst-first** · 4954 bytes

```
ROOT ELEMENT  <overdueConfig>  ->  <accountOverdueStates>  ->  <state name="...">
```

| State | Fires at | `blockChanges` | `disableEntitlement…` | Cancellation policy | KB effect | **Bridge action** |
|---|---|---|---|---|---|---|
| `CUST_OD3_CANCEL` | **30 d** | true | true | **END_OF_TERM** | cancels at end of term | existing cancel path (budget already 0) |
| `CUST_OD2_BLOCKED` | **14 d** | true | true | *(NONE default)* | entitlement blocked, **not** cancelled | **zero the budget** |
| `CUST_OD1_WARNING` | **7 d** | true | **false** | *(NONE default)* | plan changes blocked only | notify only — **no budget change** |

Every state also carries `totalUnpaidInvoiceBalanceEqualsOrExceeds = 1.00` — a floor so a stray trivial invoice can never start the ladder.

### ⚠️ THE XSD ORDERING TRAP — the bug that would have silently sunk the upload

**`overdue.xsd` is strict `xs:sequence`. ELEMENT ORDER IS MANDATORY, and validation is enforced.**

Found by validating the hand-written ladder against `https://docs.killbill.io/latest/overdue.xsd` *before* uploading — and it **FAILED**:

```
Element 'totalUnpaidInvoiceBalanceEqualsOrExceeds': This element is not expected.
Expected is one of ( responseForLastFailedPaymentIn, controlTagInclusion, controlTagExclusion ).
```

The ladder had `<timeSinceEarliest…>` before `<totalUnpaidInvoiceBalance…>`. **Reversed.** Required order inside `<condition>`:

```
1. numberOfUnpaidInvoicesEqualsOrExceeds    (xs:int)
2. totalUnpaidInvoiceBalanceEqualsOrExceeds (xs:decimal)
3. timeSinceEarliestUnpaidInvoiceEqualsOrExceeds (defaultDuration)
4. responseForLastFailedPaymentIn
5. controlTagInclusion
6. controlTagExclusion
```

Required order inside `<state>`:

```
condition -> externalMessage -> blockChanges -> disableEntitlementAndChangesBlocked
  -> subscriptionCancellationPolicy -> isClearState -> autoReevaluationInterval
  -> enterStateEmailNotification
```

> **Rule: never hand-roll this XML. Validate against the XSD first.**
> `lxml.etree.XMLSchema(etree.parse("overdue.xsd")).validate(doc)` — a two-line gate that catches the whole class of error.
> Kill Bill's own reference fixture is `jaxrs/src/test/resources/.../overdue/overdue_valid.xml`.

### Where it persists (verified)

The config is **DB-backed**, not a file — so it **survives container recreation**:

```
killbill.tenant_kvs
  tenant_key    = OVERDUE_CONFIG
  tenant_value  = <the XML, 4954 bytes>
  is_active     = 1
  created_by    = custodian-deploy
  created_date  = 2026-09-24 12:40:09
```

This matters: it is the **opposite** of the Stripe plugin-jar trap. The jar lived in the container's ephemeral layer; this lives in MariaDB. Verified `bal_pos < time_pos` in the stored bytes — the XSD-correct order is what actually persists.


### Two rules that are easy to get backwards

1. **States are evaluated in order and the FIRST match wins** (`DefaultOverdueStateSet.calculateOverdueState`). **⇒ list WORST FIRST.**
   *(`getFirstState()` returns the **last** array element — the *mildest* state. The name is misleading; don't be fooled by it.)*
2. **No explicit `clear` state is needed.** `CLEAR` is synthesised internally (`DefaultOverdueStateSet` field initialiser), and an account whose condition matches nothing resolves to it.

### Why `END_OF_TERM` is the only state that cancels
`OverdueStateApplicator.cancelSubscriptionsIfRequired()` returns immediately when the policy is `NONE` (the default). So `disableEntitlementAndChangesBlocked=true` with no policy **blocks entitlement without cancelling** — which makes OD1/OD2 **fully reversible by payment**.

### Revert / disable
POST `<overdueConfig><accountOverdueStates/></overdueConfig>` — with no states, nothing can match, so every account resolves to `CLEAR`. There is no DELETE on the resource.

---

## 3. THE BRIDGE CHANGE (designed, not yet applied)

Dispatch point — `kb_bridge.py:571`:
```python
if etype != ACTION_PAYMENT and etype not in ACTION_CANCEL:
    return "skipped", f"not actionable: {etype or '(no eventType)'}"
```

1. `ACTION_BLOCK = ("BLOCKING_STATE", "OVERDUE_CHANGE")` added to the dispatch.
2. Route it into the **existing** `on_cancel_budget` branch (`:615-619`) — that branch already calls `litellm_set_budget(budget_id, 0.0)` and is already tested. **No new budget logic.**
3. Give it its own `killbill_verify_*` corroboration, like payment and cancel have: read the engine back via `GET /1.0/kb/accounts/{id}/overdue` and require a **non-CLEAR** state before acting. A block is destructive; a request bearing the callback token must not be able to zero a paying customer.
4. Distinguish the **state name**: `CUST_OD1_WARNING` → **no budget change**; `CUST_OD2_BLOCKED` / `CUST_OD3_CANCEL` → zero.

**⚠️ Not yet verified:** the exact `eventType` string the webhook delivers for a blocking transition. The earlier research names `BLOCKING_STATE` and `OVERDUE_CHANGE`; the emitted internal event is a `BlockingTransitionInternalEvent` raised by the entitlement DAO. **This must be observed empirically, not assumed.** See §4 step 1.

---

## 4. THE TEST PLAN (and why it must be in this order)

**Step 1 — observe the real event, with NO code change.** Upload a temporary config whose only state is `numberOfUnpaidInvoicesEqualsOrExceeds = 1`. Create a test account with an unpaid invoice. The bridge will log the arriving event as `skipped: not actionable: <REAL EVENT NAME>`. **That yields the exact string from the live system** — then restore the real ladder.

**Step 2 — apply the bridge change** using the observed name.

**Step 3 — prove the cut.** Watch `kb-cust-*` budget go to **0** and confirm a request is refused with `BudgetExceededError`.

**Step 4 — prove the restore.** Restore `max_budget` **and** confirm `KB_BUDGET_DURATION` is set, because `spend >= max_budget` will otherwise keep them blocked even after the budget is raised. **This is why Track 2 (cut-off) and Track 3 (Bug #156) must ship together** — a cut-off that cannot be undone is worse than no cut-off.

---

## 5. STILL UNVERIFIED — do not assume

- The exact webhook `eventType` string for a block/unblock (§4 step 1 answers it).
- Whether a blocking transition **ever fires** on this box without an explicit re-evaluation trigger; the overdue check rides a notification queue.
- The **crypto grace window**: 14 days is currently a flat age limit that applies identically to a failed card and to a manual crypto remittance. If that proves too tight, the source-verified remedy is `controlTagInclusion` — tag the account by rail and give crypto a longer state.
- Whether `externalMessage` ever surfaces anywhere. Source shows **no email code** in the applicator — it is an inert string.
- **`enterStateEmailNotification` is a real, schema-legal element** (`<subject>`, `<templateName>`, `[isHTML]`). So Kill Bill **can** send a state-entry email itself. It needs SMTP configured (`org.killbill.*` email properties), which is **not** configured on `.104`. **Decision still stands: the bridge sends the notice via Resend (retries already built, $0).** But this is the native alternative if we ever want it — re-open only if the bridge notice proves unreliable.

---

## 5a. HOW TO AUTHENTICATE (the thing that cost an hour)

**Two independent locks. Both are required. Missing either = `401`.**

| Lock | Mechanism | Where it comes from |
|---|---|---|
| 1 | HTTP **Basic** (Shiro) | `shiro.ini`: `admin = password, root` · `root = *:*` · `/1.0/kb/** = authcBasic` |
| 2 | **`X-Killbill-ApiKey`** + **`X-Killbill-ApiSecret`** | `TenantFilter.java:80-92` → `UsernamePasswordToken(apiKey, apiSecret)` → `KillbillJdbcTenantRealm` |

Measured live from VM205 → `.104`:

| Request | Result |
|---|---|
| Basic only | **401** |
| Tenant headers only | **401** |
| **Both** | **200** ✅ |

### ⚠️ The tenant secret cannot be recovered from `.104`

`tenants.api_secret` is **one-way hashed** — proved by reproducing it independently:

```
api_secret = base64( SHA-512 × 200,000 ( raw_salt_bytes ‖ plaintext ) )
             salt = 16 random bytes, stored base64 in tenants.api_salt (24 chars)
             iterations = org.killbill.security.shiroNbHashIterations default = 200000
```
Reproduction matched the stored 88-char value **exactly**. Kill Bill's own docs agree: *"This value is hashed and stored along with the salt in the database."*

And the source states it outright — `KillbillJdbcTenantRealm.java:55`:
> `// Note: we don't support updating tenants credentials via API`

**⇒ The plaintext secret exists ONLY where it was recorded at tenant-creation time: `/opt/kb-bridge/kb-bridge.env` on VM205 (`KB_KILLBILL_API_SECRET`, 43 chars).** Kaui's copy is no help either — its column is `encrypted_api_secret`.

**Operational rule:** any Kill Bill admin call is made **from VM205**, using that env file. Use a curl config file built piecewise (`printf` into `/tmp/kbcurl.cfg`, `-K`) — it keeps credentials out of shell history and out of any transcript.


---

## 6. CHANGELOG

| Date | Change |
|---|---|
| 2026-09-24 | Created. Records the five source-verified corrections (JSON conditions, `invoiceDate` semantics, DAYS-only units, `max_budget=0` blocking, the native `budget_duration` reset), the 3-state ladder written to `.104`, the bridge design, the ordered test plan, and the honest unverified list. |
| 2026-09-24 | **LADDER ACTIVATED** (`http=201`, 12:40:09 UTC, `tenant_kvs OVERDUE_CONFIG`). Added §2 **XSD ordering trap** — the hand-written config was XSD-**invalid** (condition elements reversed) and would have been rejected; caught by validating against `overdue.xsd` before upload. Added §2 persistence proof. Added §5a **auth recipe** + the proof that `tenants.api_secret` is a one-way SHA-512×200,000 hash and therefore unrecoverable from `.104`. Corrected the `externalMessage` note — `enterStateEmailNotification` exists as a native email option. |
