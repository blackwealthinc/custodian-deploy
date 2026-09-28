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
                 "KB_KILLBILL_USER", "KB_KILLBILL_PASSWORD", "KB_VERIFY",
                 "KB_SWEEP_PAGE_SIZE", "KB_SWEEP_MAX_PAGES")}
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
        check("balance search ran to the documented end of the set",
              any("sweep complete" in ln for ln in logline), str(logline[-1:])[:130])
        # Bug #157: the balance search must not have to walk any invoice NUMBER,
        # so a missing number can no longer end reconciliation early.
        check("the run reported the set size from the pagination header",
              any("set_size=" in ln for ln in logline), str(logline[-1:])[:130])

        # Bug #157: `sweep_last_invoice_number` is now OBSERVABILITY ONLY -- it is
        # reported, never read back as a cursor.
        wm = sql("SELECT v FROM meta WHERE k='sweep_last_invoice_number'")
        check("high-water mark reported for operators (highest number seen = 13)",
              bool(wm) and wm[0]["v"] in ("13", "13.0"), str(wm))

        print()
        print("=== TEST 2: second sweep enqueues nothing (re-run is inert) ===")
        r = bridge("sweep", "--once")
        for line in (r.stdout + r.stderr).strip().splitlines()[-2:]:
            print("  log: " + line.strip()[:150])
        rows2 = sql("SELECT COUNT(*) c FROM events WHERE account_id LIKE 'acct-mock-%'")
        check("still exactly 1 event", rows2[0]["c"] == 1, f"count={rows2[0]['c']}")
        # The already-recorded invoice is skipped without even a /payments call.
        # (The underlying UNIQUE-constraint de-dupe is covered by
        # test_idempotency_and_lease.py, which exists for exactly that.)
        check("re-run skipped the known invoice instead of re-deciding it",
              any("skipped_known=1" in ln for ln in (r.stdout + r.stderr).splitlines()),
              str((r.stdout + r.stderr).strip().splitlines()[-1:])[:130])

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
        print("=== TEST 6 (Bug #157): the sweep used the BALANCE SEARCH, never walked numbers ===")
        with urllib.request.urlopen(f"{MOCK}/__hits", timeout=10) as r:
            hits = json.loads(r.read().decode())
        search = [h for h in hits if "invoices/search/" in h]
        bal = [h for h in search if "balance%5Blte%5D" in h]
        bynum = [h for h in hits if "invoices/byNumber/" in h]
        pag = [h for h in hits if "invoices/pagination" in h]
        pay = [h for h in hits if "/payments" in h]
        det = [h for h in hits if re.search(r"/invoices/inv-mock-", h)]
        check("sweep used the documented balance search", len(bal) >= 1,
              f"{len(bal)} balance-search calls")
        # Bug #157: the dead-number walk is GONE. If it ever returns, this fails --
        # which is the point: it probed 50 dead numbers per run and measured
        # ~700 KB of engine log PER RUN doing it (~67 MB/day, unbounded).
        check("sweep made ZERO byNumber calls (the dead walk is gone)",
              len(bynum) == 0, f"{len(bynum)} byNumber calls")
        # Bug #151 + the 2026-09-18 false positive: the plain list endpoint returns
        # SHALLOW invoices and reports balance 0.0 for an invoice that owes money.
        check("sweep did NOT use the shallow /invoices/pagination list",
              len(pag) == 0, f"{len(pag)} calls")
        check("sweep read /payments for the idempotency identity", len(pay) >= 1,
              f"{len(pay)} calls")
        check("worker hit the invoice detail endpoint", len(det) >= 1, f"{len(det)} calls")

        def _hits():
            with urllib.request.urlopen(f"{MOCK}/__hits", timeout=10) as rr:
                return json.loads(rr.read().decode())

        def _clear_mock_events():
            conn2 = sqlite3.connect(DBF)
            conn2.execute("DELETE FROM events WHERE account_id LIKE 'acct-mock-%'")
            conn2.commit()
            conn2.close()

        print()
        print("=== TEST 7 (Bug #157): the sweep pages the WHOLE set and stops on NextOffset ===")
        _clear_mock_events()
        env_write({"KB_SWEEP_PAGE_SIZE": "1", "KB_SWEEP_MAX_PAGES": "20"})
        n0 = len(_hits())
        r = bridge("sweep", "--once")
        out = r.stdout + r.stderr
        pages2 = [h for h in _hits()[n0:] if "invoices/search/" in h]
        rows7 = sql("SELECT * FROM events WHERE object_id='inv-mock-paid-1'")
        # Three mock invoices have balance <= 0 (paid, DRAFT, credit-only), so
        # page_size=1 must issue 3 requests: two carrying NextOffset, one without.
        check("page_size=1 forced one request per invoice", len(pages2) >= 3,
              f"{len(pages2)} page requests")
        check("paging still found exactly the right invoice", len(rows7) == 1,
              f"rows={len(rows7)}")
        check("paged run reported completion", "sweep complete" in out, out.strip()[-130:])

        print()
        print("=== TEST 8 (Bug #157): hitting the page cap is VISIBLE, never silent ===")
        _clear_mock_events()
        env_write({"KB_SWEEP_PAGE_SIZE": "1", "KB_SWEEP_MAX_PAGES": "1"})
        r = bridge("sweep", "--once")
        out = r.stdout + r.stderr
        check("page cap produced an explicit INCOMPLETE warning",
              "sweep INCOMPLETE" in out, out.strip()[-160:])
        check("the warning states coverage was NOT complete",
              "NOT complete" in out, out.strip()[-160:])
        # Blanking an env key deletes it (Bug #155), so this also proves the new
        # page knobs fall back to their defaults instead of raising at import.
        env_write({"KB_SWEEP_PAGE_SIZE": "", "KB_SWEEP_MAX_PAGES": ""})
        r = bridge("sweep", "--once")
        check("blank page knobs fall back to defaults and the sweep still runs",
              "sweep complete" in (r.stdout + r.stderr), (r.stdout + r.stderr).strip()[-130:])

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
