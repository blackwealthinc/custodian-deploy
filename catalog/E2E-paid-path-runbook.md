# E2E paid-path runbook — Kill Bill → LiteLLM budget

The exact sequence that was executed on 2026-09-18 to prove the money loop.
Every step below is a real command that returned the stated result. Use this to
re-run, to demo, or to debug when the loop breaks.

**Prereqs:** catalog uploaded (`catalog/custodian-catalog.xml`), tenant `custodian`
on `.104`, `KB_KILLBILL_*` filled in on VM205, kb-bridge units active.

Set once:
```bash
KB=http://192.168.50.104:8080
AUTH=(-u admin:password -H "X-Killbill-ApiKey: custodian" -H "X-Killbill-ApiSecret: $KB_KILLBILL_API_SECRET")
HDR=(-H "X-Killbill-CreatedBy: custodian-e2e" -H "Content-Type: application/json" -H "Accept: application/json")
```

## 1. Create the customer
```bash
curl -s "${AUTH[@]}" "${HDR[@]}" -X POST "$KB/1.0/kb/accounts" -d '{
  "name":"Demo Customer","externalKey":"cust-demo-001","email":"demo@custodian.local",
  "currency":"USD","timeZone":"America/Chicago","address1":"1 Demo Street",
  "city":"Houston","state":"TX","country":"US","postalCode":"77001","locale":"en_US"}'
# -> 201, Location: /1.0/kb/accounts/<ACCOUNT_ID>
```

## 2. Payment method — `__EXTERNAL_PAYMENT__`
Kill Bill ships this plugin built in; it records payments that happened outside
Kill Bill. No gateway needed.
```bash
curl -s "${AUTH[@]}" "${HDR[@]}" -X POST "$KB/1.0/kb/accounts/$ACCT/paymentMethods" -d '{
  "accountId":"'"$ACCT"'","externalKey":"cust-demo-001-ext-pm",
  "pluginName":"__EXTERNAL_PAYMENT__"}'
# -> 201, Location: /1.0/kb/paymentMethods/<PM_ID>
```

## 3. ⚠️ Set it as DEFAULT — do not skip
`"isDefault": true` in the create body is **silently ignored**. Without this step
Kill Bill refuses to auto-charge and the invoice log shows
`doesn't have a default payment method` → `PAYMENT_PLUGIN_API_ABORTED`.
```bash
curl -s "${AUTH[@]}" "${HDR[@]}" -X PUT \
  "$KB/1.0/kb/accounts/$ACCT/paymentMethods/$PM/setDefault" -d '{}'
# -> 204. Verify: GET /1.0/kb/accounts/$ACCT -> paymentMethodId == $PM
```
Note: **PUT**, not POST (POST → 405), and it needs a body.

## 4. Subscribe
```bash
curl -s "${AUTH[@]}" "${HDR[@]}" -X POST "$KB/1.0/kb/subscriptions" \
  -d '{"accountId":"'"$ACCT"'","planName":"basic"}'
# -> 201, Location: /1.0/kb/subscriptions/<SUB_ID>
```
**Send only `accountId` + `planName`.** Adding `productName` or `billingPeriod`
returns 400 `IllegalArgumentException` — the plan already encodes them.

Wait ~5-10 s, then confirm the invoice exists:
```bash
curl -s "${AUTH[@]}" "$KB/1.0/kb/accounts/$ACCT/invoices"
# -> invoiceNumber 1, status COMMITTED
```

## 5. Pay the invoice
```bash
INV=$(curl -s "${AUTH[@]}" "$KB/1.0/kb/accounts/$ACCT/invoices" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["invoiceId"])')
curl -s "${AUTH[@]}" "${HDR[@]}" -X POST "$KB/1.0/kb/invoices/$INV/payments" -d '{
  "accountId":"'"$ACCT"'","paymentMethodId":"'"$PM"'",
  "purchasedAmount":20.00,"currency":"USD"}'
# -> 201, Location: /1.0/kb/invoicePayments/<ID>
```
⚠️ The field is **`purchasedAmount`**. `amount` is rejected — `InvoicePaymentJson`
has no such field.

## 6. Confirm the invoice settled
```bash
curl -s "${AUTH[@]}" "$KB/1.0/kb/invoices/$INV"
# -> amount 20.0, balance 0.0, status COMMITTED   <-- the bridge's exact condition
```

## 7. Verify the budget landed — INDEPENDENTLY
Do **not** trust the worker's log line. Read LiteLLM directly (on VM205):
```bash
curl -s -X POST http://127.0.0.1:4000/budget/info \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
  -d '{"budgets":["kb-cust-demo-001"]}'
# -> "max_budget": 5.0     (retail was $20; $5 is the COST budget for plan `basic`)
```
`/budget/info` takes **`{"budgets": ["<id>"]}`** — a list of strings, not an object.

And the queue:
```bash
python3 /opt/kb-bridge/kb_bridge.py status
# -> INVOICE_PAYMENT_SUCCESS ... done  updated budget_id=kb-cust-demo-001 max_budget=5.0
```

## 8. Reconciliation sweep (dedup proof)
```bash
python3 /opt/kb-bridge/kb_bridge.py sweep --once
# -> scanned=1 new=0 watermark 0 -> 1
```
`new=0` is the **pass**, not a failure: the sweep found the same invoice the webhook
already handled and deduped it via the shared idempotency key. Only one
`INVOICE_PAYMENT_SUCCESS` row exists.

---

## Gotchas that cost time (all reproduced, all real)

| Symptom | Cause |
|---|---|
| 415 on catalog upload | endpoint consumes `text/xml`, **not** `application/xml` |
| Invoice never auto-charges, `PAYMENT_PLUGIN_API_ABORTED` | forgot step 3 — `isDefault` on create is ignored |
| 405 on setDefault | it is **PUT**, and needs a `{}` body |
| 400 `productName should not be set when planName is specified` | send `{accountId, planName}` only |
| 400 `Unrecognized field "amount"` on invoice payment | it is **`purchasedAmount`** |
| Invoice list shows `amount:0.00, balance:0.00` but by-id shows `$20 / $0` | list endpoints don't load items by default, and `amount` **and `balance`** are both computed FROM items. **Never trust a money field from a list.** Re-read by id. |
| `{"ok": false}` from the bridge | wrong path — the route is **`/kb/health`**, not `/health` |

## Note on `KB_BUDGET_DURATION`

It is currently **blank**, so no monthly reset occurs and the budget is a hard
one-time ceiling. Setting it (e.g. `30d`) makes LiteLLM reset the ceiling each
period — that is the "monthly allowance" behaviour and is still an open decision.
