#!/usr/bin/env python3
"""Part B: prove the queue -> LiteLLM budget path, idempotency, and fail-closed.

Runs on VM205 as root. Creates a throwaway budget + key, exercises both
verification modes, then cleans everything up.
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
LITELLM = "http://127.0.0.1:4000"
BUDGET_ID = "kb-bridge-test-budget"
KEY_ALIAS = "kb-bridge-test-key"
TEST_ACCOUNT = "acct-live-test"
TEST_INVOICE = "inv-live-test-1"

CONFIG = {}


def load_env():
    with open(ENVF, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                CONFIG[k.strip()] = v.strip()


def call(method, path, body=None, auth=True, timeout=25):
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if auth:
        headers["Authorization"] = f"Bearer {CONFIG.get('KB_LITELLM_MASTER_KEY', '')}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{LITELLM}{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            try:
                return r.status, json.loads(raw or "{}")
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:  # noqa: BLE001
        return 0, f"{type(e).__name__}: {e}"


def post_event(payload):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:8555/kb/events/{CONFIG['KB_PATH_TOKEN']}",
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "KillBill/1.0"},
        method="POST",
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status, json.loads(r.read().decode()), (time.time() - t0) * 1000


def set_verify(value):
    with open(ENVF, "r", encoding="utf-8") as fh:
        text = fh.read()
    text = re.sub(r"^KB_VERIFY=.*$", f"KB_VERIFY={value}", text, flags=re.M)
    with open(ENVF, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(ENVF, 0o600)
    subprocess.run(["systemctl", "restart", "kb-bridge-worker"], check=True)
    time.sleep(3)


def event_row(invoice):
    c = sqlite3.connect(DBF)
    c.row_factory = sqlite3.Row
    r = c.execute("SELECT * FROM events WHERE object_id=?", (invoice,)).fetchone()
    c.close()
    return dict(r) if r else None


def requeue(invoice):
    c = sqlite3.connect(DBF)
    c.execute("UPDATE events SET status='pending', attempts=0, next_attempt_at=0 WHERE object_id=?",
              (invoice,))
    c.commit()
    c.close()


def budget_now():
    # /budget/info takes {"budgets": [...]} -- verified against the live 422 response
    st, resp = call("POST", "/budget/info", {"budgets": [BUDGET_ID]})
    if isinstance(resp, list) and resp:
        resp = resp[0]
    return st, resp


def main():
    load_env()
    results = []

    def check(label, ok, detail=""):
        results.append((label, ok, detail))
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}  {detail}")

    # Deterministic start: a previous crashed run can leave rows that would be
    # de-duplicated, making a later "not applied" assertion pass/fail for the
    # wrong reason. Clear our test fixtures first.
    print("=== PRE-CLEAN (idempotent: makes this run independent of earlier ones) ===")
    c = sqlite3.connect(DBF)
    c.execute("DELETE FROM accounts WHERE account_id=?", (TEST_ACCOUNT,))
    c.execute("DELETE FROM events WHERE account_id=?", (TEST_ACCOUNT,))
    c.execute("DELETE FROM events WHERE object_id IN ('cfg-1','sub-live-test')")
    c.commit()
    c.close()
    print("  cleared prior test fixtures")
    print()

    print("=== SETUP: throwaway budget + key ===")
    st, resp = call("POST", "/budget/new", {"budget_id": BUDGET_ID, "max_budget": 0.0})
    print(f"  budget/new -> {st} {str(resp)[:120]}")

    st, resp = call("POST", "/key/generate",
                    {"key_alias": KEY_ALIAS, "budget_id": BUDGET_ID,
                     "models": ["deepseek-v4-flash"]})
    print(f"  key/generate -> {st}")
    test_key = resp.get("key") if isinstance(resp, dict) else None
    print(f"  test key created: {bool(test_key)}")

    print()
    print("=== MAP: link a Kill Bill account to that budget ===")
    r = subprocess.run(["python3", f"{BASE}/kb_bridge.py", "map",
                        "--account-id", TEST_ACCOUNT, "--budget-id", BUDGET_ID,
                        "--plan", "basic", "--note", "part-B test"],
                       capture_output=True, text=True)
    print("  " + (r.stdout or r.stderr).strip())

    print()
    print("=== TEST 1: VERIFY=1 with NO Kill Bill creds -> must REFUSE (fail-closed) ===")
    set_verify(1)
    st, body, ms = post_event({"eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
                               "objectId": TEST_INVOICE, "accountId": TEST_ACCOUNT,
                               "tenantId": "tenant-live-test"})
    print(f"  receiver http={st} ack={ms:.1f}ms  {body}")
    time.sleep(8)
    row = event_row(TEST_INVOICE)
    # fail-closed == the event did NOT get applied. The worker parks it as
    # 'pending' (retry/backoff) or 'failed' -- either way it must carry the refusal.
    refused = (
        row
        and row["status"] in ("failed", "pending")
        and "verification refused" in (row["last_error"] or "")
    )
    check("fail-closed: event refused without Kill Bill creds", bool(refused),
          f"status={row['status'] if row else '?'} err={(row['last_error'] or '')[:70] if row else ''}")
    st, info = budget_now()
    mb = info.get("max_budget") if isinstance(info, dict) else None
    check("LiteLLM budget untouched by refused event", mb == 0.0, f"max_budget={mb}")

    print()
    print("=== TEST 2: VERIFY=0 -> worker applies the plan budget to LiteLLM ===")
    set_verify(0)
    requeue(TEST_INVOICE)
    time.sleep(7)
    row = event_row(TEST_INVOICE)
    check("event processed", bool(row) and row["status"] == "done",
          f"status={row['status'] if row else '?'} msg={(row['last_error'] or '')[:80] if row else ''}")
    st, info = budget_now()
    mb = info.get("max_budget") if isinstance(info, dict) else None
    check("LiteLLM budget set to plan value (basic=5.0)", mb == 5.0,
          f"max_budget={mb}  raw={str(info)[:120]}")

    print()
    print("=== TEST 3: idempotency -- replay the same event ===")
    before = budget_now()[1]
    st, body, ms = post_event({"eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
                               "objectId": TEST_INVOICE, "accountId": TEST_ACCOUNT,
                               "tenantId": "tenant-live-test"})
    check("duplicate detected", body.get("duplicate") is True, str(body))
    time.sleep(4)
    row = event_row(TEST_INVOICE)
    after = budget_now()[1]
    check("no second application (attempts unchanged)", row["attempts"] == 1,
          f"attempts={row['attempts']}  budget {before.get('max_budget')} -> {after.get('max_budget')}")

    print()
    print("=== TEST 4: cancellation path -> budget zeroed ===")
    st, body, ms = post_event({"eventType": "SUBSCRIPTION_CANCEL", "objectType": "SUBSCRIPTION",
                               "objectId": "sub-live-test", "accountId": TEST_ACCOUNT,
                               "tenantId": "tenant-live-test"})
    print(f"  receiver http={st} ack={ms:.1f}ms {body}")
    time.sleep(7)
    row = event_row("sub-live-test")
    check("cancel event processed", bool(row) and row["status"] == "done",
          f"status={row['status'] if row else '?'}")
    st, info = budget_now()
    mb = info.get("max_budget") if isinstance(info, dict) else None
    check("budget zeroed on cancel", mb == 0.0, f"max_budget={mb}")

    print()
    print("=== TEST 5: non-actionable event is acknowledged, not an error ===")
    st, body, ms = post_event({"eventType": "TENANT_CONFIG_CHANGE", "objectType": "TENANT_KVS",
                               "objectId": "cfg-1", "accountId": None, "tenantId": "tenant-live-test"})
    time.sleep(4)
    row = event_row("cfg-1")
    check("noisy event skipped cleanly", bool(row) and row["status"] == "skipped",
          f"status={row['status'] if row else '?'}")

    print()
    print("=== CLEANUP ===")
    if test_key:
        st, resp = call("POST", "/key/delete", {"keys": [test_key]})
        print(f"  key/delete -> {st} {str(resp)[:100]}")
    st, resp = call("POST", "/budget/delete", {"id": BUDGET_ID})
    print(f"  budget/delete -> {st} {str(resp)[:100]}")
    c = sqlite3.connect(DBF)
    c.execute("DELETE FROM accounts WHERE account_id=?", (TEST_ACCOUNT,))
    c.execute("DELETE FROM events WHERE account_id=? OR source='sweep'", (TEST_ACCOUNT,))
    c.execute("DELETE FROM events WHERE object_id='cfg-1'")
    c.commit()
    c.close()
    set_verify(1)
    print("  bridge test rows removed; KB_VERIFY restored to 1")

    print()
    passed = sum(1 for _, ok, _ in results if ok)
    print(f"=== RESULT: {passed}/{len(results)} checks passed ===")
    for label, ok, detail in results:
        if not ok:
            print(f"  FAILED: {label} -- {detail}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
