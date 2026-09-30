#!/usr/bin/env python3
"""Phase 3 cut-off — unit test against the REAL captured event payloads.

Runs entirely locally: no live Kill Bill, no live LiteLLM. The payloads below are
the verbatim shapes captured from VM205 (events 334/335/336), so this test asserts
against reality rather than against a guess.

WHY NOT the VM205 suite: tests/test_*.py in this directory MUTATE
/opt/kb-bridge/kb-bridge.env and call 127.0.0.1:4000 / :8555. They are for the live
box. This file has no side effects.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault("KB_DB", "/tmp/cutoff-test.db")

import kb_bridge as B  # noqa: E402

ACCT = "41080fda-d2b6-4515-be1a-547f1ba83638"
KEY_HASH = "a" * 64

# --- the real payloads, verbatim from VM205 ------------------------------------
# event 335 -- BLOCKING_STATE, note metaData is a STRING, not an object
REAL_BLOCKING_WARN = {
    "eventType": "BLOCKING_STATE",
    "accountId": ACCT,
    "objectType": "ACCOUNT",
    "objectId": ACCT,
    "metaData": json.dumps({
        "blockableId": ACCT, "service": "overdue-service",
        "stateName": "CUST_OD1_WARNING", "blockingType": "ACCOUNT",
        "effectiveDate": "2026-09-29T20:50:02.000Z",
        "transitionedToBlockedBilling": False,
        "transitionedToUnblockedBilling": False,
        "transitionedToBlockedEntitlement": False,
        "transitionedToUnblockedEntitlement": False,
    }),
}
# event 334 -- INVOICE_PAYMENT_FAILED, note paymentId is null
REAL_PAYMENT_FAILED = {
    "eventType": "INVOICE_PAYMENT_FAILED",
    "accountId": ACCT,
    "objectType": "INVOICE",
    "objectId": "4b964a85-ed83-45a5-9938-88ff53bc513f",
    "metaData": json.dumps({
        "paymentId": None, "paymentAttemptId": "246986a1-4f5a-4b1b-beee-9e215300a89e",
        "invoicePaymentType": "ATTEMPT", "paymentDate": "2026-09-29T20:50:02.000Z",
        "amount": None, "currency": "USD", "linkedInvoicePaymentId": None,
        "paymentCookieId": "d9d60a48-8b79-4e8d-9141-0bced88bb359",
        "processedCurrency": None,
    }),
}

BLOCKED = dict(REAL_BLOCKING_WARN, metaData=json.dumps({
    "stateName": "CUST_OD2_BLOCKED", "service": "overdue-service",
    "blockingType": "ACCOUNT",
}))
CLEAR = dict(REAL_BLOCKING_WARN, metaData=json.dumps({
    "stateName": "CLEAR", "service": "overdue-service", "blockingType": "ACCOUNT",
}))

results = []


def check(name, got, want):
    ok = got == want
    results.append(ok)
    print("  %-58s %s" % (name, "PASS" if ok else "FAIL"))
    if not ok:
        print("        got : %r" % (got,))
        print("        want: %r" % (want,))


def with_stubs(payload, key_hash=KEY_HASH, verify=(True, "verified: 1 unpaid")):
    """Run handle_blocking_state with block/verify intercepted."""
    calls = []
    orig_block = B.litellm_set_blocked
    orig_verify = B.killbill_verify_account_overdue
    B.litellm_set_blocked = lambda ref, blocked: (calls.append((ref, blocked)), (True, "stub ok"))[1]
    B.killbill_verify_account_overdue = lambda a: verify
    try:
        acct = {"litellm_key_hash": key_hash}
        row = {"payload": json.dumps(payload)}
        return B.handle_blocking_state(acct, row, ACCT), calls  # type: ignore[arg-type]
    finally:
        B.litellm_set_blocked = orig_block
        B.killbill_verify_account_overdue = orig_verify


print("Phase 3 cut-off — real-payload tests")
print()

# 1. day-7 warning must NOT cut anything
(status, msg), calls = with_stubs(REAL_BLOCKING_WARN)
check("OD1 warning -> status done", status, "done")
check("OD1 warning -> NOTHING cut (no block call)", calls, [])
check("OD1 warning -> reason says so", "nothing is cut" in msg, True)

# 2. day-14 blocking state MUST cut, and must cut THE KEY
(status, msg), calls = with_stubs(BLOCKED)
check("OD2 blocked -> status done", status, "done")
check("OD2 blocked -> blocked the key hash", calls, [(KEY_HASH, True)])
check("OD2 blocked -> reason names the cut", "cut-off" in msg, True)

# 3. a forged block with no real unpaid invoice must be REFUSED
(status, msg), calls = with_stubs(
    BLOCKED, verify=(False, "no unpaid invoice for this account -- refusing to cut")
)
check("OD2 + no unpaid invoice -> failed", status, "failed")
check("OD2 + no unpaid invoice -> no block call", calls, [])
check("OD2 + no unpaid invoice -> says refused", "refusing to cut" in msg, True)

# 4. CLEAR (synthesised when they pay) must restore
(status, msg), calls = with_stubs(CLEAR, verify=(False, "no unpaid invoice"))
check("CLEAR -> status done", status, "done")
check("CLEAR -> UNblocked the key", calls, [(KEY_HASH, False)])
check("CLEAR -> reason names the restore", "restore" in msg, True)

# 5. CLEAR while they still owe must NOT restore
(status, msg), calls = with_stubs(CLEAR, verify=(True, "verified: 1 unpaid invoice"))
check("CLEAR + still owes -> declined (no unblock)", calls, [])
check("CLEAR + still owes -> reason says declined", "declined to restore" in msg, True)

# 6. no key hash -> cannot act either way, and must not retry forever
(status, msg), calls = with_stubs(BLOCKED, key_hash="")
check("OD2 with no key hash -> done (not a retry loop)", status, "done")
check("OD2 with no key hash -> no block call", calls, [])
check("OD2 with no key hash -> says why", "no litellm_key_hash" in msg, True)

# 7. a genuinely malformed payload fails loudly rather than silently
(status, msg), _ = with_stubs({"eventType": "BLOCKING_STATE", "metaData": None})
check("no metaData -> failed", status, "failed")

# 8. INVOICE_PAYMENT_FAILED is recorded, never acted on
status, msg = B.process_event(  # type: ignore[arg-type]
        None, {"event_type": "INVOICE_PAYMENT_FAILED",
               "account_id": ACCT, "payload": json.dumps(REAL_PAYMENT_FAILED)})
check("payment failed -> done (recorded)", status, "done")
check("payment failed -> ladder owns the policy", "overdue ladder owns" in msg, True)

# 9. an unrelated event type is still skipped, not actioned
status, msg = B.process_event(  # type: ignore[arg-type]
        None, {"event_type": "SOME_OTHER_EVENT", "account_id": ACCT, "payload": "{}"})
check("unrelated event -> still skipped", status, "skipped")

# --- Bug #166: the idem key must distinguish a cut from a restore --------------
# Real transitions from the live box, 2026-09-30: OD2 at 19:27:45 then CLEAR at
# 19:28:36. Both were received; the CLEAR one arrived `fresh=False` and was
# discarded, so the cut could never be undone.
REAL_CUT = dict(REAL_BLOCKING_WARN, metaData=json.dumps({
    "blockableId": ACCT, "service": "overdue-service",
    "stateName": "CUST_OD2_BLOCKED", "blockingType": "ACCOUNT",
    "effectiveDate": "2026-09-30T19:27:45.000Z",
    "transitionedToBlockedEntitlement": True,
}))
REAL_CLEAR = dict(REAL_BLOCKING_WARN, metaData=json.dumps({
    "blockableId": ACCT, "service": "overdue-service",
    "stateName": "__KILLBILL__CLEAR__OVERDUE_STATE__", "blockingType": "ACCOUNT",
    "effectiveDate": "2026-09-30T19:28:36.000Z",
    "transitionedToUnblockedEntitlement": True,
}))
SECOND_CUT = dict(REAL_CUT, metaData=json.dumps({
    "blockableId": ACCT, "service": "overdue-service",
    "stateName": "CUST_OD2_BLOCKED", "blockingType": "ACCOUNT",
    "effectiveDate": "2026-11-02T08:00:00.000Z",
}))

raw_cut = json.dumps(REAL_CUT).encode()
k_cut = B.idem_key_of(REAL_CUT, raw_cut)
k_clear = B.idem_key_of(REAL_CLEAR, json.dumps(REAL_CLEAR).encode())
k_second = B.idem_key_of(SECOND_CUT, json.dumps(SECOND_CUT).encode())

check("#166 cut and CLEAR -> DIFFERENT idem keys", k_cut != k_clear, True)
check("#166 a SECOND cut -> DIFFERENT key (no silent re-cut)",
      k_cut != k_second, True)
check("#166 re-delivery of the SAME cut -> same key (still dedupes)",
      B.idem_key_of(REAL_CUT, raw_cut), k_cut)

# regression guard: the fix is conditional, so no OTHER event's key may change
want = B.hashlib.sha256("|".join([
    "INVOICE_PAYMENT_SUCCESS", "INVOICE", "inv-1", ACCT, "pay-1",
]).encode()).hexdigest()
pay = {"eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
       "objectId": "inv-1", "accountId": ACCT,
       "metaData": json.dumps({"paymentId": "pay-1"})}
check("#166 payment event key UNCHANGED by the fix",
      B.idem_key_of(pay, b"{}"), want)

# and a BLOCKING_STATE with unparseable metaData must never collide either
bad_a = {"eventType": "BLOCKING_STATE", "objectType": "ACCOUNT",
         "objectId": ACCT, "accountId": ACCT, "metaData": "not json"}
bad_b = dict(bad_a, metaData="also not json")
check("#166 unidentifiable transitions -> DIFFERENT keys",
      B.idem_key_of(bad_a, b"aaa") != B.idem_key_of(bad_b, b"bbb"), True)

print()
print("%d/%d passed" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
