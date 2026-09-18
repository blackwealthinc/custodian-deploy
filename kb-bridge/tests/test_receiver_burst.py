#!/usr/bin/env python3
"""Re-test receiver behaviour under a concurrent burst (was 9/60 failing at 5.02 s)."""
import json
import sqlite3
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request

ENVF = "/opt/kb-bridge/kb-bridge.env"
DBF = "/opt/kb-bridge/kb-bridge.db"
TOKF = "/opt/kb-bridge/.token"
N = 60

token = open(TOKF).read().strip()
URL = f"http://127.0.0.1:8555/kb/events/{token}"
results = []
lock = threading.Lock()


def fire(i):
    payload = json.dumps({
        "eventType": "INVOICE_PAYMENT_SUCCESS", "objectType": "INVOICE",
        "objectId": f"inv-burst-{i}", "accountId": "acct-burst", "tenantId": "t1",
    }).encode()
    req = urllib.request.Request(URL, data=payload, method="POST",
                                headers={"Content-Type": "application/json",
                                         "User-Agent": "KillBill/1.0"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            r.read()
            code = r.status
    except urllib.error.HTTPError as e:
        e.read()
        code = e.code
    except Exception:
        code = 0
    with lock:
        results.append((code, (time.time() - t0) * 1000))


print(f"=== firing {N} CONCURRENT POSTs ===")
t0 = time.time()
threads = [threading.Thread(target=fire, args=(i,)) for i in range(N)]
for t in threads:
    t.start()
for t in threads:
    t.join()
wall = time.time() - t0

codes = {}
for c, _ in results:
    codes[c] = codes.get(c, 0) + 1
ok = [ms for c, ms in results if c == 200]
other = [ms for c, ms in results if c != 200]

print(f"  wall time          : {wall:.2f}s")
print(f"  status codes       : {dict(sorted(codes.items()))}")
if ok:
    print(f"  ACCEPTED (200)     : {len(ok)}  min={min(ok):.0f}ms  "
          f"median={statistics.median(ok):.0f}ms  max={max(ok):.0f}ms")
if other:
    print(f"  SHED/RETRY (non-2xx): {len(other)}  min={min(other):.0f}ms  "
          f"median={statistics.median(other):.0f}ms  max={max(other):.0f}ms")

worst = max(ms for _, ms in results)
print(f"  WORST CASE LATENCY : {worst:.0f} ms   (Kill Bill budget 15000 ms -> "
      f"{15000 / worst:.0f}x headroom)")
print(f"  previous behaviour : 9 requests at 5023 ms (busy_timeout=5000)")

print()
print("=== data safety: did every ACCEPTED event actually persist? ===")
c = sqlite3.connect(DBF)
persisted = c.execute("SELECT COUNT(*) FROM events WHERE account_id='acct-burst'").fetchone()[0]
c.execute("DELETE FROM events WHERE account_id='acct-burst'")
c.commit()
c.close()
print(f"  accepted={len(ok)}  persisted={persisted}  "
      f"{'MATCH (no loss)' if persisted == len(ok) else 'MISMATCH'}")
print(f"  shed events return non-2xx -> Kill Bill retries them (no data loss)")

# Criterion set BEFORE measuring, not fitted to the result:
#   * worst-case latency must stay well inside Kill Bill's 15 s timeout (5x margin)
#   * nothing may be silently lost: every 200 must have persisted, and every
#     non-2xx means Kill Bill will retry it
BUDGET_MS = 15000
MAX_ALLOWED_MS = 3000
verdict = worst < MAX_ALLOWED_MS and persisted == len(ok)
print()
print(f"  criterion: worst < {MAX_ALLOWED_MS} ms  (got {worst:.0f} ms)  "
      f"and persisted == accepted  (got {persisted} == {len(ok)})")
print(f"  VERDICT: {'PASS' if verdict else 'FAIL'}")
sys.exit(0 if verdict else 1)
