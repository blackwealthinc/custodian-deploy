# Phase 2 re-audit — 2026-09-29

Adversarial re-audit of the Phase 2 top-up build, at the user's request ("reaudit and strongman;
see if you got anything wrong"). Two of my claims were wrong, one money-facing. One is fixed and
proven live; one is critical and needs a decision. This file is the public-safe summary; the full
working record is in the project's research folder.

## 1. The ceiling must be written where the enforcer reads it (fixed, proven)

Phase 2 wrote the ceiling with `POST /budget/update` (the budget **object**). That is only enforced
when the key carries no ceiling of its own.

Live A/B/C probe against the running v1.95.0:

| Key shape | Enforced ceiling |
|---|---|
| `budget_id` linked, key has no own `max_budget` | the budget **object's** value |
| key carries its **own** `max_budget` (with or without a `budget_id`) | the **key's** value; the object is ignored |
| reverse control (key value set back to 0.0) | blocked again — the key's value is the live input |

Mechanism (`litellm/proxy/_types.py`, `LiteLLM_VerificationTokenView.__init__`): the table's value is
copied onto the token **only when the key's own value is `None`**. Upstream treats this as fragile —
PR #43018 ("enforce key max_budget from budget_id table") was still **open** when this was written.

`setup-custodian-factory.sh` creates customer keys **with their own `max_budget`**, so the object
write was inert for every real customer: a $11.50 top-up would have moved nothing.

**Fix:** the key is the single source of truth. `litellm_set_budget()` now calls
`POST /key/update {"key": <sha256 hash>, "max_budget": N}` (the hash is accepted; `exclude_unset`
means the provisioning `budget_duration` is preserved), with the budget object kept as the fallback
for an account with no key hash. `litellm_key_state()` reads the key's value first (`is not None`, so
a real `0.0` counts) else the object's. All four ceiling writes pass the key hash — top-up,
subscription renewal, **cancellation**, and the sweep's reconcile.

**Proof (real Kill Bill → real LiteLLM):**

```
event 339 INVOICE_PAYMENT_SUCCESS [done]
  top-up: charged 11.5 -> credit 10.000000; granted total 10.000000;
  ceiling 15.000000; updated key max_budget=15.0

before: KEY max_budget=None   object max_budget=5.0
after : KEY max_budget=15.0   object max_budget=5.0
```

## 2. Nothing collects the money, and the engine will "pay" a top-up by itself (open, critical)

With a **default payment method** and **no `AUTO_PAY_OFF`** tag, Kill Bill attempts payment when an
invoice is committed. On this box the only method is `__EXTERNAL_PAYMENT__` — the plugin Kill Bill
documents as *"used to track payments which occurred outside of Kill Bill"*. It **succeeds**, so:

```
account payments: count = 4        (three were created by hand earlier; the 4th is new)
  8ebe8921  PURCHASE  SUCCESS  11.5  method=__EXTERNAL_PAYMENT__
invoice b8a4a979: amount=11.5 balance=0.0 creditAdj=0.0 refundAdj=0.0 credits=null
account tags: []                    (no AUTO_PAY_OFF)
```

The bridge equates `INVOICE_PAYMENT_SUCCESS` with *money received*. On this rail that is false:
**creating a top-up charge grants the tokens for free, automatically, with no money anywhere.**

An earlier probe of mine reported "no auto-pay" — that test was **void**: the payment method it
installed ended up with `isDefault: false`, so auto-pay was never eligible. A negative result is
only evidence once the preconditions are verified.

Fix needs a rail decision (Phase 3): a real rail as the default method (the Stripe plugin), or
`AUTO_PAY_OFF` plus an explicit charge — and, in the bridge, refusing to credit when the payment's
method resolves to `__EXTERNAL_PAYMENT__`.

## 3. Corrections to my own earlier claims

- **"budget_id-linked keys are never reset"** — WRONG. Live test: a key with the duration on the key
  *and* a key with the duration only on the linked budget object **both** went `spend → 0.0` at the
  same tick. I had read part of `reset_budget_job.py` and generalised. Not shipped as a "fix",
  because it was not broken.
- **"the budget table is never read for keys"** — WRONG (a false-negative grep, contradicted by the
  same probe's own output). `LiteLLM_VerificationTokenView.__init__` reads it whenever the key's own
  value is unset.
- **"`litellm_key_state` shadows the key's reset time with a null"** — eliminated; the API returns
  `litellm_budget_table: null`, so the fallback works.

## 4. Held up on re-verification

Fee basis (15% on top, `credit = paid ÷ 1.15`, from `pricing/reseller-pricing-model.md` §2/§4);
external charge as the mechanism for an arbitrary one-time amount; `CUSTODIAN_TOPUP` in `itemDetails`
as the discriminator; `X-Killbill-CreatedBy` required on Kill Bill writes; the two ledger traps.

## 5. Also open

- A **second** payment against one top-up invoice credits the full amount again: the credit is the
  *item* amount and is granted per `paymentId`. A $5.75 partial payment on an $11.50 invoice grants
  the full $10. Fix: grant once per invoice and base the credit on the amount actually paid.
- `POST /budget/delete` returns 422; the working payment-method delete in 0.24.21 is
  `DELETE /1.0/kb/paymentMethods/{pmid}?forceDelete=true` (204). The account-scoped path 404s.

## 6. Method notes

- The redactor wrote `***` **into a file**, breaking quotes (`syntax error near unexpected token`).
  The same line pattern was byte-perfect in the next file, and displayed as `***` in a third.
  **Always `grep -c '\*\*\*'` + `bash -n` after writing; confirm bytes, not the screen.**
- A scheduled job's outcome must not be read before its interval has elapsed — measure `date -u`
  against the row's `budget_reset_at` before concluding "no reset".
- Backgrounded output was lost to buffering twice; a bounded *foreground* sampler with UTC stamps is
  the reliable shape for timed observation.
