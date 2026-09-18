#!/usr/bin/env python3
"""Part C: exercise the SWEEP and the VERIFICATION function (both untested before).

Before this test:
  * the sweep parsed Payment.status / Payment.invoiceId -- neither field exists,
    so it matched nothing, forever, while reporting success.
  * the verification read Invoice.paidAmount -- which exists in no Kill Bill
    schema -- so it refused EVERY event once credentials were configured.

Runs against a mock Kill Bill on 127.0.0.1:8556. Cleans up fully.
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = "/opt/kb-bridge"
ENVF = f"{BASE}/kb-bridge.env"
DBF = f"{BASE}/kb-bridge.db"
MOCK = "http://127.0.0.1:8556"
LITELLM = "http://127.0.0.1:4000"
BUDGET_ID = "kb-sweep-test-budget"
ACCT = "acct-mock-1"

results = []


def check(label, ok, detail=""):
    results.append((label, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}  {detail}")


def env_read():
    cfg = {}
    with open(ENVF, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip()
    return cfg


def env_write(updates):
    """Write config values. An EMPTY value means DELETE the key, never `KEY=`.

    A present-but-blank value is not the same as an absent one: the bridge's
    os.environ.get(name, default) returns "" and float("") crashed at import
    (Bug #155). Restores must remove the line, not blank it.
    """
    text = open(ENVF, encoding="utf-8").read()
    for k, v in updates.items():
        if v == "":
            text = re.sub(rf"^{re.escape(k)}=.*$\n?", "", text, flags=re.M)
        elif re.search(rf"^{re.escape(k)}=.*$", text, flags=re.M):
            text = re.sub(rf"^{re.escape(k)}=.*$", f"{k}={v}", text, flags=re.M)
        else:
            text += f"\n{k}={v}\n"
    open(ENVF, "w", encoding="utf-8").write(text)
    os.chmod(ENVF, 0o600)


def litellm(method, path, body=None):
    cfg = env_read()
    h = {"Authorization": f"Bearer {cfg.get('KB_LITELLM_MASTER_KEY', '')}",
         "Content-Type": "application/json", "Accept": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{LITELLM}{path}", data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read().decode()
            try:
                return r.status, json.loads(raw or "{}")
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


def budget_value():
    st, d = litellm("POST", "/budget/info", {"budgets": [BUDGET_ID]})
    if isinstance(d, list) and d:
        d = d[0]
    return d.get("max_budget") if isinstance(d, dict) else None


def sql(q, args=()):
    c = sqlite3.connect(DBF)
    c.row_factory = sqlite3.Row
    rows = [dict(r) for r in c.execute(q, args)]
    c.close()
    return rows


def post_event(payload):
    cfg = env_read()
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:8555/kb/events/{cfg['KB_PATH_TOKEN']}", data=body,
        headers={"Content-Type": "application/json", "User-Agent": "KillBill/1.0"},
        method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status, json.loads(r.read().decode())


def bridge(*args):
    return subprocess.run(["python3", f"{BASE}/kb_bridge.py", *args],
                          capture_output=True, text=True)


def reset_worker():
    subprocess.run(["systemctl", "restart", "kb-bridge-worker"], check=True)
    time.sleep(3)


def main():
    cfg0 = env_read()
    original = {k: cfg0.get(k, "") for k in
                ("KB_KILLBILL_URL", "KB_KILLBILL_API_KEY", "KB_KILLBILL_API_SECRET",
                 "KB_KILLBILL_USER", "KB_KILLBILL_PASSWORD", "KB_VERIFY")}
    test_key = None

    try:
        print("=== PRE-CLEAN ===")
        c = sqlite3.connect(DBF)
        c.execute("DELETE FROM events WHERE account_id LIKE 'acct-mock-%'")
        c.execute("DELETE FROM accounts WHERE account_id LIKE 'acct-mock-%'")
        c.execute("DELETE FROM meta WHERE k='sweep_last_invoice_number'")
        c.commit()
        c.close()
        print("  cleared")

        print()
        print("=== SETUP: test budget, mapping, mock credentials ===")
        st, resp = litellm("POST", "/budget/new", {"budget_id": BUDGET_ID, "max_budget": 0.0})
        print(f"  budget/new -> {st}")
        r = bridge("map", "--account-id", ACCT, "--budget-id", BUDGET_ID, "--plan", "basic")
        print("  " + (r.stdout or r.stderr).strip())
        env_write({
            "KB_KILLBILL_URL": MOCK,
            "KB_KILLBILL_API_KEY": "mock-key",
            "KB_KILLBILL_API_SECRET": "mock-secret",
            "KB_KILLBILL_USER": "mock-user",
            "KB_KILLBILL_PASSWORD": "mock-pass",
            "KB_VERIFY": "1",
        })
        reset_worker()
        print("  mock credentials installed; worker restarted (VERIFY=1)")

        print()
        print("=== TEST 1: sweep finds the ONE fully-paid invoice, skips the other three ===")
        r = bridge("sweep", "--once")
        logline = (r.stdout + r.stderr).strip().splitlines()
        for line in logline[-3:]:
            print("  log: " + line.strip()[:150])
        rows = sql("SELECT * FROM events WHERE account_id LIKE 'acct-mock-%'")
        ids = sorted({row["object_id"] for row in rows})
        check("exactly 1 event enqueued", len(rows) == 1, f"rows={len(rows)} ids={ids}")
        check("it is the fully-paid invoice", ids == ["inv-mock-paid-1"], str(ids))
        check("partial (balance>0) skipped", "inv-mock-unpaid" not in ids, str(ids))
        check("DRAFT skipped", "inv-mock-draft" not in ids, str(ids))
        # A fully-paid invoice with NO payment on record was settled by credit, so
        # no money moved and no budget may be granted.
        check("credit-only (no payment) skipped", "inv-mock-credit" not in ids, str(ids))
        check("walk terminated cleanly via the 4018 end sentinel",
              any("sweep complete" in ln for ln in logline), str(logline[-1:])[:130])

        wm = sql("SELECT v FROM meta WHERE k='sweep_last_invoice_number'")
        check("watermark advanced to the highest number (13)",
              bool(wm) and wm[0]["v"] in ("13", "13.0"), str(wm))

        print()
        print("=== TEST 2: second sweep enqueues nothing (watermark works) ===")
        r = bridge("sweep", "--once")
        for line in (r.stdout + r.stderr).strip().splitlines()[-2:]:
            print("  log: " + line.strip()[:150])
        rows2 = sql("SELECT COUNT(*) c FROM events WHERE account_id LIKE 'acct-mock-%'")
        check("still exactly 1 event", rows2[0]["c"] == 1, f"count={rows2[0]['c']}")

        print()
        print("=== TEST 3: the FIXED verification accepts a genuinely paid invoice ===")
        time.sleep(8)
        row = sql("SELECT * FROM events WHERE object_id='inv-mock-paid-1'")
        core = row[0] if row else None
        check("event processed (not refused)", bool(core) and core["status"] == "done",
              f"status={core['status'] if core else '?'} msg={(core['last_error'] or '')[:90] if core else ''}")
        val = budget_value()
        check("budget applied from plan (basic=5.0)", val == 5.0, f"max_budget={val}")

        print()
        print("=== TEST 4: verification REFUSES a partially-paid invoice ===")
        st, body = post_event({"eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
                               "objectId": "inv-mock-unpaid", "accountId": "acct-mock-2",
                               "tenantId": "t-mock"})
        print(f"  posted -> {st} {body}")
        r = bridge("map", "--account-id", "acct-mock-2", "--budget-id", BUDGET_ID, "--plan", "pro")
        time.sleep(9)
        row = sql("SELECT * FROM events WHERE object_id='inv-mock-unpaid'")
        core = row[0] if row else None
        err = (core["last_error"] or "") if core else ""
        check("refused with a partial-payment reason",
              bool(core) and core["status"] in ("failed", "pending") and "not fully paid" in err,
              f"status={core['status'] if core else '?'} err={err[:90]}")
        val = budget_value()
        check("budget unchanged by the refused event", val == 5.0, f"max_budget={val}")

        print()
        print("=== TEST 5: verification REFUSES a non-committed (DRAFT) invoice ===")
        r = bridge("map", "--account-id", "acct-mock-3", "--budget-id", BUDGET_ID, "--plan", "pro")
        st, body = post_event({"eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
                               "objectId": "inv-mock-draft", "accountId": "acct-mock-3",
                               "tenantId": "t-mock"})
        time.sleep(9)
        row = sql("SELECT * FROM events WHERE object_id='inv-mock-draft'")
        core = row[0] if row else None
        err = (core["last_error"] or "") if core else ""
        check("refused with a not-committed reason",
              bool(core) and core["status"] in ("failed", "pending") and "not committed" in err,
              f"status={core['status'] if core else '?'} err={err[:90]}")

        print()
        print("=== TEST 5b: verification REFUSES an invoice owned by another account ===")
        # Found by accident in an earlier run: posting a valid invoice but claiming
        # the wrong accountId trips the ownership check. Assert it deliberately.
        st, body = post_event({"eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
                               "objectId": "inv-mock-paid-1", "accountId": "acct-mock-3",
                               "tenantId": "t-mock"})
        time.sleep(9)
        row = sql("SELECT * FROM events WHERE object_id='inv-mock-paid-1' AND account_id='acct-mock-3'")
        core = row[0] if row else None
        err = (core["last_error"] or "") if core else ""
        check("refused with an ownership reason",
              bool(core) and core["status"] in ("failed", "pending")
              and "does not belong" in err,
              f"status={core['status'] if core else '?'} err={err[:90]}")
        check("budget still untouched", budget_value() == 5.0, f"max_budget={budget_value()}")

        print()
        print("=== TEST 6: the sweep walked by NUMBER, never paged from offset 0 ===")
        with urllib.request.urlopen(f"{MOCK}/__hits", timeout=10) as r:
            hits = json.loads(r.read().decode())
        bynum = [h for h in hits if "invoices/byNumber/" in h]
        pag = [h for h in hits if "invoices/pagination" in h]
        pay = [h for h in hits if "/payments" in h]
        det = [h for h in hits if re.search(r"/invoices/inv-mock-", h)]
        # Bug #151: paging from offset 0 with a page cap is blind past
        # SWEEP_MAX_PAGES*100 invoices, and it is blind in the worst possible way
        # -- silently, and only once the tenant is big enough to matter.
        check("sweep walked byNumber", len(bynum) >= 4, f"{len(bynum)} calls")
        check("sweep did NOT page from offset 0", len(pag) == 0, f"{len(pag)} calls")
        check("sweep read /payments for the idempotency identity", len(pay) >= 1,
              f"{len(pay)} calls")
        check("worker hit the invoice detail endpoint", len(det) >= 1, f"{len(det)} calls")
        # Gap tolerance: invoice numbers 1-9 do not exist in the mock, yet the walk
        # had to pass through them to reach invoice 10. Stopping at the first
        # missing number would stall reconciliation permanently at that gap.
        before10 = [h for h in bynum
                    if h.rsplit("/", 1)[-1].isdigit() and int(h.rsplit("/", 1)[-1]) < 10]
        check("gap tolerance: probed missing numbers below 10 before finding it",
              len(before10) >= 9, f"{len(before10)} probes")

    finally:
        print()
        print("=== CLEANUP (guaranteed) ===")
        litellm("POST", "/budget/delete", {"id": BUDGET_ID})
        c = sqlite3.connect(DBF)
        c.execute("DELETE FROM events WHERE account_id LIKE 'acct-mock-%'")
        c.execute("DELETE FROM accounts WHERE account_id LIKE 'acct-mock-%'")
        c.execute("DELETE FROM meta WHERE k='sweep_last_invoice_number'")
        c.commit()
        c.close()
        env_write(original)
        reset_worker()
        cfg = env_read()
        print(f"  KB_KILLBILL_URL restored to {cfg.get('KB_KILLBILL_URL')!r}")
        print(f"  KB_VERIFY restored to {cfg.get('KB_VERIFY')!r}")
        print("  test rows + budget removed")

    print()
    passed = sum(1 for _, ok, _ in results if ok)
    print(f"=== RESULT: {passed}/{len(results)} checks passed ===")
    for label, ok, detail in results:
        if not ok:
            print(f"  FAILED: {label} -- {detail}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
