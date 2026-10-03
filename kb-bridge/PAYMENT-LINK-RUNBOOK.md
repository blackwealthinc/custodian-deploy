# Payment-Link (no-autopay) reseller — monthly runbook

**Why this exists:** a reseller who chose **"Payment Link"** instead of "save card for autopay" has
no card on file. The Stripe plugin (8.0.4) has **no webhooks** (`processNotification()` = "not yet
implemented"), so a Payment Link charge is **invisible to Kill Bill** until we record it manually.
This runbook is that recording step.

**Trigger:** monthly, per reseller who is on "no autopay".

---

## The monthly sequence

1. Kill Bill generates the reseller's invoice (subscription cycle, `basic` = $20, `pro` = $59,
   `business` = $200).
2. Send the reseller a **Stripe Payment Link** for that invoice amount.
   (Dashboard → Payment Links → Create, or `POST https://api.stripe.com/v1/payment_links` with
   `line_items[][price_data]` for the amount. For 2 resellers, the dashboard is fine.)
3. The reseller pays (out-of-band — Kill Bill does not see this).
4. **Record the payment** in Kill Bill (below).
5. `INVOICE_PAYMENT_SUCCESS` fires → bridge grants the LiteLLM budget. No code change.

## The recording call (run FROM VM205)

```bash
curl -s -u admin:<rotated> \
  -H "X-Killbill-ApiKey: <tenant-5-key>" -H "X-Killbill-ApiSecret: <tenant-5-secret>" \
  -H "X-Killbill-CreatedBy: custodian-paymentlink" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -X POST "http://192.168.50.104:8080/1.0/kb/invoices/<INVOICE_ID>/payments?externalPayment=true" \
  --data-binary '{"accountId": "<ACCOUNT_ID>", "purchasedAmount": 20.00}'
```

- `externalPayment=true` means "recorded as paid externally"; it **forbids** a `paymentMethodId`.
- All four credentials live in `/opt/kb-bridge-licence/kb-bridge.env` on VM205 (mode 600).

## Matching (manual, the important bit)

The Stripe payment and the Kill Bill invoice are separate records. Match by **account + amount**:

1. In the Stripe dashboard, see the Payment Link charge (who paid, how much).
2. In Kill Bill, find the reseller's open invoice: `GET /1.0/kb/accounts/{id}/invoices`.
3. Confirm the invoice amount equals the Stripe charge amount for that same reseller.
4. Record with the call above.

**Two rules:**
- Read the invoice **by ID** (`?withItems=true`) for the real amount — the LIST endpoint lies
  (`amount 0.00`).
- The response can be **204 No Content** even when the payment was recorded — judge success by the
  invoice `balance` going to `0`, not the status code.

## Verification (after recording)

- `GET /1.0/kb/invoices/{id}?withItems=true` → `balance: 0.0`.
- Bridge `events` table shows `INVOICE_PAYMENT_SUCCESS` → `done` (budget granted).

## When to automate

At 2 resellers this manual step is fine. At scale (P10), replace step 4 with a Stripe webhook
receiver that reads the invoice id from Payment Link metadata and records it automatically. Do not
build that now.

---

*Companion: `killbill-invoicing-and-topups.md` §2 (the externalPayment path, verified live).*
