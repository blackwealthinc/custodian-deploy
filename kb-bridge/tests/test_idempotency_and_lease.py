#!/usr/bin/env python3
"""Regression coverage for Bug #149, #150 and #153.

Three defects that no existing test could see, each fixed here and pinned so it
cannot come back:

  #149  the idempotency key hashed (eventType|objectType|objectId|accountId), and
        for INVOICE_PAYMENT_* the objectId is the INVOICE. Two distinct payments
        on one invoice therefore shared one key: the second was rejected by the
        UNIQUE constraint and ACKed as `duplicate`, so the customer paid and got
        no budget.
  #150  claim_batch set status='processing' and NOTHING ever reclaimed it. A
        worker killed mid-batch stranded those payments permanently, and
        invisibly: 'processing' is neither 'pending' nor 'failed'.
  #153  the cancellation path "verified" only that credentials were configured,
        so any request bearing the callback path token could zero a paying
        customer's budget.

Runs against the mock Kill Bill on 127.0.0.1:8556. Cleans up fully.
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
BUDGET_ID = "kb-regress-budget"
ACCT = "acct-mock-1"
INV = "inv-mock-paid-1"

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
    """Write config values into the env file. An EMPTY value means DELETE the key.

    Writing `KEY=` (present but blank) is what turned Bug #155 from "crash on
    import" into "silently disables verification", so the restore path must remove
    the line rather than blank it.
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


def sqlw(q, args=()):
    c = sqlite3.connect(DBF)
    n = c.execute(q, args).rowcount
    c.commit()
    c.close()
    return n


def post_event(payload):
    cfg = env_read()
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:8555/kb/events/{cfg['KB_PATH_TOKEN']}", data=body,
        headers={"Content-Type": "application/json", "User-Agent": "KillBill/1.0"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]


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
                 "KB_LEASE_SECONDS")}

    try:
        print("=== PRE-CLEAN ===")
        sqlw("DELETE FROM events WHERE account_id LIKE 'acct-mock-%' OR idem_key LIKE 'TEST-%'")
        sqlw("DELETE FROM accounts WHERE account_id LIKE 'acct-mock-%'")
        sqlw("DELETE FROM meta WHERE k='sweep_last_invoice_number'")
        print("  cleared")

        print()
        print("=== SETUP ===")
        st, _ = litellm("POST", "/budget/new", {"budget_id": BUDGET_ID, "max_budget": 5.0})
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
        print("  mock credentials installed; worker restarted")

        # ------------------------------------------------------------------ #
        print()
        print("=== TEST 1 (Bug #149): two payments on ONE invoice get DIFFERENT keys ===")
        sys.path.insert(0, BASE)
        import kb_bridge  # noqa: PLC0415

        def key_of(payment_id):
            payload = {
                "eventType": "INVOICE_PAYMENT_SUCCESS",
                "objectType": "INVOICE",
                # The SAME invoice, exactly as Kill Bill reports it for both payments.
                "objectId": INV,
                "accountId": ACCT,
                "metaData": json.dumps({"paymentId": payment_id}),
            }
            return kb_bridge.idem_key_of(payload, b"x")

        k1, k2 = key_of("pay-multi-a"), key_of("pay-multi-b")
        check("payment A and payment B produce different keys", k1 != k2,
              f"{k1[:16]}.. vs {k2[:16]}..")
        check("the same payment is stable (retries still collapse)",
              key_of("pay-multi-a") == k1, "stable")

        print()
        print("=== TEST 2 (Bug #149): both payments are QUEUED, not silently dropped ===")
        e1 = {"eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
              "objectId": INV, "accountId": ACCT,
              "metaData": json.dumps({"paymentId": "pay-multi-a"})}
        e2 = dict(e1, metaData=json.dumps({"paymentId": "pay-multi-b"}))
        st1, b1 = post_event(e1)
        st2, b2 = post_event(e2)
        b1 = b1 if isinstance(b1, dict) else {}
        b2 = b2 if isinstance(b2, dict) else {}
        print(f"  post A -> {st1} {b1}")
        print(f"  post B -> {st2} {b2}")
        n = sql("SELECT COUNT(*) c FROM events WHERE object_id=? AND account_id=?", (INV, ACCT))
        check("BOTH payment events queued (previously the 2nd was dropped)",
              n[0]["c"] == 2, f"rows={n[0]['c']}")
        check("neither response claimed to be a duplicate",
              b1.get("duplicate") is False and b2.get("duplicate") is False,
              f"{b1} / {b2}")

        print()
        print("=== TEST 3 (Bug #149): a genuine Kill Bill RETRY is still collapsed ===")
        st3, b3 = post_event(e1)  # same paymentId -> same key -> duplicate
        b3 = b3 if isinstance(b3, dict) else {}
        print(f"  repost A -> {st3} {b3}")
        n = sql("SELECT COUNT(*) c FROM events WHERE object_id=? AND account_id=?", (INV, ACCT))
        check("repost deduplicated (still 2 rows)", n[0]["c"] == 2, f"rows={n[0]['c']}")
        check("repost answered duplicate=true", b3.get("duplicate") is True, str(b3))

        # ------------------------------------------------------------------ #
        print()
        print("=== TEST 4 (Bug #150): an EXPIRED lease is reclaimed and processed ===")
        now = time.time()
        sqlw("INSERT INTO events(idem_key,received_at,source,event_type,object_type,account_id,"
             "object_id,payload,status,attempts,next_attempt_at,lease_token,lease_expires_at,owner)"
             " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
             ("TEST-LEASE-STALE", now, "test", "TEST_NONACTIONABLE", "TEST", None, None, "{}",
              "processing", 1, 0, "stale-token", now - 120, "dead-worker:1"))
        row = sql("SELECT status FROM events WHERE idem_key='TEST-LEASE-STALE'")
        check("planted as 'processing' with an expired lease", row[0]["status"] == "processing",
              str(row))
        time.sleep(12)  # worker loop: reclaim, then claim, then process
        row = sql("SELECT status, lease_token, lease_expires_at FROM events"
                  " WHERE idem_key='TEST-LEASE-STALE'")
        check("reclaimed and processed (no longer 'processing')",
              row and row[0]["status"] != "processing",
              f"status={row[0]['status'] if row else '?'}")
        check("lease cleared on completion", bool(row) and row[0]["lease_token"] is None,
              f"lease_token={row[0]['lease_token'] if row else '?'}")

        print()
        print("=== TEST 5 (Bug #150): a LIVE lease is NOT stolen ===")
        sqlw("INSERT INTO events(idem_key,received_at,source,event_type,object_type,account_id,"
             "object_id,payload,status,attempts,next_attempt_at,lease_token,lease_expires_at,owner)"
             " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
             ("TEST-LEASE-HELD", time.time(), "test", "TEST_NONACTIONABLE", "TEST", None, None, "{}",
              "processing", 1, 0, "live-token", time.time() + 3000, "live-worker:9"))
        time.sleep(10)
        row = sql("SELECT status, attempts FROM events WHERE idem_key='TEST-LEASE-HELD'")
        check("still held (a healthy worker keeps its row)", row[0]["status"] == "processing",
              f"status={row[0]['status']} attempts={row[0]['attempts']}")

        print()
        print("=== TEST 6 (Bug #150): a zombie worker cannot clobber a reclaimed row ===")
        n = sqlw("UPDATE events SET status='done' WHERE idem_key='TEST-LEASE-HELD'"
                 " AND lease_token=?", ("stale-token",))
        check("write with a stale lease_token is refused (rowcount 0)", n == 0, f"rowcount={n}")
        row = sql("SELECT status FROM events WHERE idem_key='TEST-LEASE-HELD'")
        check("row untouched by the stale writer", row[0]["status"] == "processing",
              f"status={row[0]['status']}")

        print()
        print("=== TEST 7 (Bug #150): status surfaces abandoned rows ===")
        r = bridge("status")
        out = r.stdout
        check("status reports the lease/abandoned line", "abandoned" in out,
              str([l for l in out.splitlines() if "lease" in l][:1]))

        # ------------------------------------------------------------------ #
        print()
        print("=== TEST 8 (Bug #153): a cancel for an ACTIVE subscription is REFUSED ===")
        st, body = post_event({"eventType": "SUBSCRIPTION_CANCEL", "objectType": "SUBSCRIPTION",
                               "objectId": "sub-mock-active", "accountId": ACCT})
        print(f"  posted -> {st} {body}")
        time.sleep(10)
        row = sql("SELECT status, last_error FROM events WHERE object_id='sub-mock-active'"
                  " ORDER BY id DESC LIMIT 1")
        err = (row[0]["last_error"] or "") if row else ""
        check("refused because the subscription has not ended",
              bool(row) and row[0]["status"] in ("failed", "pending") and "not ended" in err,
              f"status={row[0]['status'] if row else '?'} err={err[:90]}")
        check("budget NOT zeroed by the refused cancel", budget_value() == 5.0,
              f"max_budget={budget_value()}")

        print()
        print("=== TEST 9 (Bug #153): a cancel for a CANCELLED subscription is APPLIED ===")
        st, body = post_event({"eventType": "SUBSCRIPTION_CANCEL", "objectType": "SUBSCRIPTION",
                               "objectId": "sub-mock-cancelled", "accountId": ACCT})
        print(f"  posted -> {st} {body}")
        time.sleep(10)
        row = sql("SELECT status, last_error FROM events WHERE object_id='sub-mock-cancelled'"
                  " ORDER BY id DESC LIMIT 1")
        check("applied", bool(row) and row[0]["status"] == "done",
              f"status={row[0]['status'] if row else '?'} "
              f"err={(row[0]['last_error'] or '')[:80] if row else ''}")
        check("budget driven to on_cancel_budget (0.0)", budget_value() == 0.0,
              f"max_budget={budget_value()}")

        print()
        print("=== TEST 10 (Bug #153): a cancel with the WRONG objectType is REFUSED ===")
        st, body = post_event({"eventType": "SUBSCRIPTION_CANCEL", "objectType": "INVOICE",
                               "objectId": INV, "accountId": ACCT})
        print(f"  posted -> {st} {body}")
        time.sleep(10)
        row = sql("SELECT status, last_error FROM events WHERE object_type='INVOICE'"
                  " AND event_type='SUBSCRIPTION_CANCEL' ORDER BY id DESC LIMIT 1")
        err = (row[0]["last_error"] or "") if row else ""
        check("refused (cannot be verified against the engine)",
              bool(row) and row[0]["status"] in ("failed", "pending")
              and "cannot be verified" in err,
              f"status={row[0]['status'] if row else '?'} err={err[:90]}")

        print()
        print("=== TEST 11 (Bug #155): a BLANK config value must not crash or downgrade ===")
        # Found while running this very suite: the restore helper wrote
        # `KB_LEASE_SECONDS=` (present but blank), and os.environ.get(name, default)
        # returns "" for that, so float("") raised at IMPORT and the bridge refused
        # to start. Worse: a blank KB_VERIFY= evaluated to False, silently turning
        # fail-closed verification into fail-open.
        text = open(ENVF, encoding="utf-8").read()
        text += "\nKB_LEASE_SECONDS=\nKB_VERIFY=\nKB_SWEEP_MAX_INVOICES=\n"
        open(ENVF, "w", encoding="utf-8").write(text)
        os.chmod(ENVF, 0o600)
        r = subprocess.run(
            ["python3", "-c",
             f"import sys; sys.path.insert(0, {BASE!r}); import kb_bridge as k; "
             "print('LEASE', k.LEASE_SECONDS); print('VERIFY', k.VERIFY); "
             "print('MAXINV', k.SWEEP_MAX_INVOICES)"],
            capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        print("  import output: " + out.replace("\n", " | ")[:190])

        def _pick(prefix):
            for ln in out.splitlines():
                if ln.startswith(prefix):
                    return ln.strip()
            return out[:80]

        check("module still imports with blank values (no ValueError)", r.returncode == 0,
              f"rc={r.returncode}")
        check("blank KB_LEASE_SECONDS falls back to its default 600",
              "LEASE 600.0" in out, _pick("LEASE"))
        check("blank KB_VERIFY stays TRUE (fail-closed NOT downgraded)",
              "VERIFY True" in out, _pick("VERIFY"))
        check("blank KB_SWEEP_MAX_INVOICES falls back to 200", "MAXINV 200" in out, _pick("MAXINV"))
        env_write({"KB_LEASE_SECONDS": "", "KB_VERIFY": "", "KB_SWEEP_MAX_INVOICES": ""})

    finally:
        print()
        print("=== CLEANUP (guaranteed) ===")
        litellm("POST", "/budget/delete", {"id": BUDGET_ID})
        sqlw("DELETE FROM events WHERE account_id LIKE 'acct-mock-%' OR idem_key LIKE 'TEST-%'")
        sqlw("DELETE FROM accounts WHERE account_id LIKE 'acct-mock-%'")
        sqlw("DELETE FROM meta WHERE k='sweep_last_invoice_number'")
        env_write(original)
        reset_worker()
        print("  test rows + budget removed; env restored; worker restarted")

    print()
    passed = sum(1 for _, ok, _ in results if ok)
    print(f"=== RESULT: {passed}/{len(results)} checks passed ===")
    for label, ok, detail in results:
        if not ok:
            print(f"  FAILED: {label} -- {detail}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
