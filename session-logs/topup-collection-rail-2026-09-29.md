# Top-up collection + the rail guard — 2026-09-29

Follow-on from `phase2-reaudit-2026-09-29.md`.

## Collection needs no new glue

`research/stripe-crypto-decisions-research-2026-09-18.txt` §1.2 already recorded it: the
plugin's hosted checkout (`POST /plugins/killbill-stripe/checkout`, session `mode: "setup"`)
saves a card; **Kill Bill then auto-charges every committed invoice** — a subscription
renewal or a top-up external charge — and the resulting `INVOICE_PAYMENT_SUCCESS` is the
event the bridge already consumes.

Confirmed at source, tag `stripe-plugin-8.0.4`,
`StripePaymentPluginApi.purchasePayment` -> `executeInitialTransaction(PURCHASE, …)`:

```
amount        = the invoice amount
capture_method= CaptureMethod.AUTOMATIC
confirm       = true          <- an actual charge
customer      = the saved Stripe customer
```

So auto-pay is the **intended** collection mechanism, not a defect. The defect was that the
demo account's default payment method is Kill Bill's bookkeeping plugin instead of a real
gateway's, so the payment attempt "succeeded" with no money.

## Bug #162 (#150) — a top-up could credit twice

The credit was the invoice ITEM amount, granted once per `metaData.paymentId`. Two payments
against one invoice are two events, so `granted += credit` ran twice, and a part-payment was
worth full value.

**Fix:** a `topup_grants` row per invoice. The entitlement is recomputed from the amount
actually **paid** (`amount − balance`, capped at the line item) and only the **delta**
reaches the ledger.

**Proven** (deployed module + live DB): $5.75 → delta 5.0; second $5.75 → delta 5.0 (total
10.0, not 20); the same event replayed → delta 0.0; $50 paid on an $11.50 invoice → capped
at 10.0.

## Bug #163 (#151) — a payment is not proof of money

Kill Bill's `__EXTERNAL_PAYMENT__` plugin records money that arrived *outside* Kill Bill,
and the engine reaches for it when an account's default payment method is not a real
gateway. One such payment settled a real top-up invoice with no money anywhere.

**Fix:** every account carries a rail. `card` (default) refuses a payment whose method
plugin is `__EXTERNAL_PAYMENT__`; `manual` (crypto/offline — a recorded payment *is* the
confirmation) credits it. Fail-closed. The refusal is retried with backoff, so correcting a
mis-set rail heals the real payments; the reason string says so, because flipping a rail
credits the refused events retroactively.

**Proven live:** `rail=card` → `refusing a __EXTERNAL_PAYMENT__ payment …`, ledger and
ceiling untouched; `rail=manual` → `done`, entitlement 10.0, ceiling raised on the key;
`AUTO_PAY_OFF` → the charge leaves the invoice `amount=11.5 balance=11.5 payments=0` and the
account payment count does not move.

## Endpoint shapes (Kill Bill 0.24.21)

- add a tag: `POST /1.0/kb/accounts/{id}/tags` with a **JSON array of tag-definition UUIDs**
  (`["00000000-0000-0000-0000-000000000001"]` = `AUTO_PAY_OFF`) → 201. A `Tag` **object**
  body returns 400 "cannot deserialize ArrayList<UUID> from Object value" — the error names
  the shape.
- delete a payment method: `DELETE /1.0/kb/paymentMethods/{pmid}?forceDelete=true` → 204.
- `POST /budget/delete` → 422.

## Still unproven

**A real charge.** Everything here is engine-level; no money has moved. The last link is to
save a card through the hosted checkout, let a renewal charge it, and refund it — needs a
real card, so it is the user's call (Phase 3, paid-path Step 3).

## Demo configuration (deliberate)

`cust-demo-001` runs **rail=manual + `AUTO_PAY_OFF`**: no real gateway, so the engine never
auto-pays and a hand-recorded payment is the confirmation — the crypto/offline pattern.
