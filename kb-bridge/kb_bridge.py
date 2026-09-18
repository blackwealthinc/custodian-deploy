#!/usr/bin/env python3
"""
Kill Bill -> LiteLLM budget bridge (Custodian reseller platform)
================================================================

One file, two long-running processes, zero third-party dependencies
(stdlib only -- VM205 has ~760 MiB free, so we do not pay for FastAPI/uvicorn).

    kb_bridge.py receiver   # fast-ACK HTTP endpoint. Kill Bill POSTs events here.
    kb_bridge.py worker     # drains the local queue -> applies budgets in LiteLLM
    kb_bridge.py sweep      # reconciliation: polls Kill Bill for events the webhook missed
    kb_bridge.py init       # create the SQLite schema + seed default plans
    kb_bridge.py status     # queue depth / recent activity / config sanity
    kb_bridge.py map        # add/update an account -> budget mapping
    kb_bridge.py plan       # add/update a plan -> budget amount

WHY THIS SHAPE
--------------
Kill Bill's push-notification POST is made BY Kill Bill, on its own event-bus
thread, with a 15 second timeout (PushNotificationListener.TIMEOUT_NOTIFICATION).
So the receiver must ACK in milliseconds: it does nothing but persist the event
and return 200. All real work happens in the worker.

Kill Bill also sends NO authentication header -- only `User-Agent: KillBill/1.0`
and `Content-Type: application/json; charset=UTF-8`. The callback URL is a single
value per tenant, so the only place to put a secret is the URL PATH. That makes it
a noise filter, not real auth -- the real control is the network layer (bind to
the LAN address, firewall to the Kill Bill host only). Because of that, an inbound
event is NEVER trusted on its own: the worker re-verifies against Kill Bill before
granting anything (KB_VERIFY=on, fail-closed).

Delivery is at-least-once and retries are bounded (default 15m,30m,2h,12h,1d),
so events CAN be lost -- hence `sweep`.

Idempotency: a UNIQUE key over (tenant, eventType, objectType, objectId, account)
collapses Kill Bill's retries into a single application.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import logging
import os
import signal
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = logging.getLogger("kb-bridge")


def _load_env_file(path: str) -> None:
    """Load KEY=VALUE from an env file for CLI/admin runs.

    systemd injects EnvironmentFile= already; this makes direct invocations
    (`kb_bridge.py status`, `map`, `plan`) see the same config instead of
    silently reporting empty secrets.
    """
    if not path or not os.path.exists(path):
        return
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, _, value = line.partition("=")
                name, value = name.strip(), value.strip()
                if name and name not in os.environ:
                    os.environ[name] = value
    except OSError:
        pass


_load_env_file(os.environ.get("KB_ENV_FILE", "/opt/kb-bridge/kb-bridge.env"))

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #


def cfg(name: str, default: str | None = None, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        LOG.error("FATAL: %s is required but not set", name)
        sys.exit(2)
    return val or ""


def cfg_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


DB_PATH = cfg("KB_DB_PATH", "/opt/kb-bridge/kb-bridge.db")
BIND = cfg("KB_BIND", "0.0.0.0")
PORT = int(cfg("KB_PORT", "8555"))
PATH_TOKEN = os.environ.get("KB_PATH_TOKEN", "")
LITELLM_URL = cfg("KB_LITELLM_URL", "http://127.0.0.1:4000").rstrip("/")
LITELLM_KEY = os.environ.get("KB_LITELLM_MASTER_KEY", "")
BUDGET_DURATION = os.environ.get("KB_BUDGET_DURATION", "").strip()
KILLBILL_URL = cfg("KB_KILLBILL_URL", "").rstrip("/")
KB_API_KEY = os.environ.get("KB_KILLBILL_API_KEY", "")
KB_API_SECRET = os.environ.get("KB_KILLBILL_API_SECRET", "")
KB_USER = os.environ.get("KB_KILLBILL_USER", "")
KB_PASSWORD = os.environ.get("KB_KILLBILL_PASSWORD", "")
VERIFY = cfg_bool("KB_VERIFY", True)
MAX_BODY = int(cfg("KB_MAX_BODY", "262144"))
BATCH = int(cfg("KB_WORKER_BATCH", "10"))
POLL_SECONDS = float(cfg("KB_WORKER_POLL_SECONDS", "2"))
MAX_ATTEMPTS = int(cfg("KB_MAX_ATTEMPTS", "8"))
HTTP_TIMEOUT = float(cfg("KB_HTTP_TIMEOUT", "20"))
SWEEP_MAX_PAGES = int(cfg("KB_SWEEP_MAX_PAGES", "20"))
SWEEP_INTERVAL_SECONDS = float(cfg("KB_SWEEP_INTERVAL_SECONDS", "900"))

# --- receiver hardening ---------------------------------------------------- #
# The receiver must NEVER park a Kill Bill event-bus thread. Kill Bill's shipped
# bus config is `persistent.bus.main.nbThreads=1`, so a stalled callback can stop
# ALL event dispatch. Two guards:
#   * a SHORT sqlite busy timeout -> a blocked write fails fast (500 -> retry)
#     instead of waiting seconds (measured 5.02 s at the 5000 ms default)
#   * a bounded concurrency slot -> shed load with 503 rather than spawning an
#     unbounded thread per connection under MemoryMax
RECV_BUSY_TIMEOUT_MS = int(cfg("KB_RECV_BUSY_TIMEOUT_MS", "250"))
MAX_CONCURRENT = int(cfg("KB_MAX_CONCURRENT", "32"))
# Wait this long for a free slot before shedding. 0 would shed the very first
# burst instantly; a small wait absorbs a spike while still bounding the worst
# case (wait + busy timeout ~= 0.4 s, versus Kill Bill's 15 s budget).
RECV_SLOT_WAIT_SECONDS = float(cfg("KB_RECV_SLOT_WAIT_SECONDS", "0.15"))
_SLOTS = threading.BoundedSemaphore(MAX_CONCURRENT)

# Event types we act on. Anything else is acknowledged and marked 'skipped'.
ACTION_PAYMENT = "INVOICE_PAYMENT_SUCCESS"
ACTION_CANCEL = ("SUBSCRIPTION_CANCEL", "SUBSCRIPTION_EXPIRED")

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    idem_key        TEXT    NOT NULL UNIQUE,
    received_at     REAL    NOT NULL,
    source          TEXT    NOT NULL DEFAULT 'webhook',
    event_type      TEXT,
    object_type     TEXT,
    account_id      TEXT,
    object_id       TEXT,
    tenant_id       TEXT,
    payload         TEXT    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'pending',
    attempts        INTEGER NOT NULL DEFAULT 0,
    last_error      TEXT,
    next_attempt_at REAL    NOT NULL DEFAULT 0,
    processed_at    REAL
);
CREATE INDEX IF NOT EXISTS idx_events_ready ON events(status, next_attempt_at);

CREATE TABLE IF NOT EXISTS accounts (
    account_id TEXT PRIMARY KEY,
    budget_id  TEXT,
    key_alias  TEXT,
    plan       TEXT,
    active     INTEGER NOT NULL DEFAULT 1,
    note       TEXT,
    updated_at REAL
);

CREATE TABLE IF NOT EXISTS plans (
    plan_name        TEXT PRIMARY KEY,
    max_budget       REAL NOT NULL,
    on_cancel_budget REAL NOT NULL DEFAULT 0,
    updated_at       REAL
);

CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
"""


def db(busy_ms: int = 5000) -> sqlite3.Connection:
    """Open the queue database.

    busy_ms is the SQLite busy timeout. The RECEIVER deliberately passes a short
    one: if the worker holds the write lock it must fail fast so Kill Bill gets a
    quick 500 (and retries) instead of having an event-bus thread parked for
    seconds. The worker keeps a long timeout because it is the primary writer.
    """
    conn = sqlite3.connect(DB_PATH, timeout=busy_ms / 1000.0, isolation_level=None)
    conn.row_factory = sqlite3.Row
    # NOTE: journal_mode=WAL is PERSISTENT in the database file, so it is set once
    # by init_db(). Re-issuing it on every open is measurable work under a burst.
    # synchronous is per-connection (default FULL = fsync per commit) so it stays.
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute(f"PRAGMA busy_timeout={int(busy_ms)}")
    return conn


def init_db(seed: bool = True) -> None:
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = db()
    try:
        conn.executescript(SCHEMA)
        if seed:
            now = time.time()
            defaults = [("basic", 5.0, 0.0), ("pro", 20.0, 0.0), ("business", 100.0, 0.0)]
            for name, budget, cancel in defaults:
                conn.execute(
                    "INSERT OR IGNORE INTO plans(plan_name,max_budget,on_cancel_budget,updated_at)"
                    " VALUES(?,?,?,?)",
                    (name, budget, cancel, now),
                )
    finally:
        conn.close()


# --------------------------------------------------------------------------- #
# HTTP helpers
# --------------------------------------------------------------------------- #


def http_json(method: str, url: str, body: dict | None = None, headers: dict | None = None,
              timeout: float = HTTP_TIMEOUT) -> tuple[int, dict | list | str]:
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Content-Type": "application/json", "Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            try:
                return resp.status, json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw
    except Exception as exc:  # noqa: BLE001 - network layer, we want the message
        return 0, f"{type(exc).__name__}: {exc}"


def litellm_headers() -> dict:
    return {"Authorization": f"Bearer {LITELLM_KEY}"}


def litellm_set_budget(budget_id: str, max_budget: float) -> tuple[bool, str]:
    """Set a budget's ceiling. Update first; create if it does not exist."""
    payload: dict = {"budget_id": budget_id, "max_budget": max_budget}
    if BUDGET_DURATION:
        payload["budget_duration"] = BUDGET_DURATION

    status, resp = http_json("POST", f"{LITELLM_URL}/budget/update", payload, litellm_headers())
    if status == 200:
        return True, f"updated budget_id={budget_id} max_budget={max_budget}"

    LOG.warning("budget/update failed (%s): %s -- trying budget/new", status, str(resp)[:200])
    status2, resp2 = http_json("POST", f"{LITELLM_URL}/budget/new", payload, litellm_headers())
    if status2 == 200:
        return True, f"created budget_id={budget_id} max_budget={max_budget}"

    return False, f"budget/update http={status} {str(resp)[:160]}; budget/new http={status2} {str(resp2)[:160]}"


def killbill_headers() -> dict:
    h = {"Accept": "application/json"}
    if KB_API_KEY:
        h["X-Killbill-ApiKey"] = KB_API_KEY
    if KB_API_SECRET:
        h["X-Killbill-ApiSecret"] = KB_API_SECRET
    if KB_USER and KB_PASSWORD:
        token = base64.b64encode(f"{KB_USER}:{KB_PASSWORD}".encode()).decode()
        h["Authorization"] = f"Basic {token}"
    return h


def killbill_configured() -> bool:
    return bool(KILLBILL_URL and KB_API_KEY and KB_API_SECRET and KB_USER and KB_PASSWORD)


def killbill_verify_invoice_paid(account_id: str, invoice_id: str) -> tuple[bool, str]:
    """Re-verify a claimed payment against Kill Bill. Fail closed.

    Field names verified against the live swagger `definitions/Invoice`:
      * status  : enum DRAFT | COMMITTED | VOID   -- there is NO "PAID" status
      * balance : number, 0.0 == fully paid
      * there is NO `paidAmount` field anywhere in the Kill Bill API.
        An earlier version of this function read it, so every verification
        failed and every payment event was refused.
    """
    if not killbill_configured():
        return False, "killbill credentials not configured (fail-closed)"
    if not invoice_id:
        return False, "event carried no invoice id to verify"

    status, resp = http_json(
        "GET",
        f"{KILLBILL_URL}/1.0/kb/invoices/{invoice_id}",
        None,
        killbill_headers(),
    )
    if status != 200 or not isinstance(resp, dict):
        return False, f"invoice lookup http={status} {str(resp)[:140]}"

    owner = resp.get("accountId")
    if owner and account_id and owner != account_id:
        return False, "invoice does not belong to the claimed account"

    state = str(resp.get("status") or "").upper()
    balance = resp.get("balance")
    amount = resp.get("amount")

    if balance is None:
        return False, f"invoice returned no balance field (status={state or 'missing'}) - refusing"
    if state != "COMMITTED":
        return False, f"invoice not committed (status={state or 'missing'})"
    if float(balance) > 0:
        return False, (
            f"invoice not fully paid: balance={balance} amount={amount} "
            f"(a partial payment does not grant a budget)"
        )
    return True, f"verified: status={state} balance={balance} amount={amount}"


# --------------------------------------------------------------------------- #
# Event -> action
# --------------------------------------------------------------------------- #


def idem_key_of(payload: dict, raw: bytes, source: str = "webhook") -> str:
    # tenantId is DELIBERATELY excluded. The sweep and the webhook describe the
    # same underlying payment but cannot know the same tenantId (the sweep runs
    # on one tenant's credentials). Including it produced two different keys for
    # one payment, so the sweep would re-apply what the webhook had already done.
    # objectId is a Kill Bill UUID, globally unique, so it is sufficient alone.
    parts = [
        str(payload.get("eventType") or ""),
        str(payload.get("objectType") or ""),
        str(payload.get("objectId") or ""),
        str(payload.get("accountId") or ""),
    ]
    if all(not p for p in parts):
        return hashlib.sha256(raw).hexdigest()
    return hashlib.sha256("|".join(parts).encode()).hexdigest()


def enqueue(conn: sqlite3.Connection, payload: dict, raw: bytes, source: str = "webhook") -> bool:
    key = idem_key_of(payload, raw, source)
    try:
        conn.execute(
            "INSERT INTO events(idem_key,received_at,source,event_type,object_type,account_id,"
            "object_id,tenant_id,payload) VALUES(?,?,?,?,?,?,?,?,?)",
            (
                key,
                time.time(),
                source,
                payload.get("eventType"),
                payload.get("objectType"),
                payload.get("accountId"),
                payload.get("objectId"),
                payload.get("tenantId"),
                raw.decode("utf-8", "replace"),
            ),
        )
        return True
    except sqlite3.IntegrityError:
        return False  # duplicate -- already queued


def process_event(conn: sqlite3.Connection, row: sqlite3.Row) -> tuple[str, str]:
    """Returns (new_status, message). new_status in {done, skipped, failed}."""
    etype = (row["event_type"] or "").upper()
    account_id = row["account_id"] or ""

    if etype == "SUBSCRIPTION_CHANGE":
        # Deliberately unhandled for now: deciding the NEW budget needs a
        # subscription -> plan lookup against Kill Bill, which does not exist yet.
        # Say so loudly rather than silently doing nothing -- the budget stays at
        # the old plan's value until the next payment event.
        return "skipped", (
            "SUBSCRIPTION_CHANGE not yet handled: budget unchanged until the next "
            "payment; needs a subscription->plan lookup"
        )

    if etype != ACTION_PAYMENT and etype not in ACTION_CANCEL:
        return "skipped", f"not actionable: {etype or '(no eventType)'}"

    if not account_id:
        return "skipped", "no accountId on event"

    acct = conn.execute(
        "SELECT * FROM accounts WHERE account_id=? AND active=1", (account_id,)
    ).fetchone()
    if acct is None:
        return "skipped", f"no active mapping for account {account_id}"

    budget_id = acct["budget_id"]
    if not budget_id:
        return "failed", f"mapping for {account_id} has no budget_id"

    if VERIFY:
        if etype == ACTION_PAYMENT:
            ok, why = killbill_verify_invoice_paid(account_id, row["object_id"] or "")
        else:
            ok, why = (killbill_configured(), "cancellation requires killbill credentials (fail-closed)")
        if not ok:
            return "failed", f"verification refused: {why}"

    if etype == ACTION_PAYMENT:
        plan = acct["plan"]
        prow = conn.execute("SELECT * FROM plans WHERE plan_name=?", (plan,)).fetchone()
        if prow is None:
            return "failed", f"no plan row for plan={plan!r} (account {account_id})"
        amount = float(prow["max_budget"])
        ok, msg = litellm_set_budget(budget_id, amount)
        return ("done" if ok else "failed"), msg

    # cancellation
    prow = conn.execute("SELECT * FROM plans WHERE plan_name=?", (acct["plan"],)).fetchone()
    amount = float(prow["on_cancel_budget"]) if prow else 0.0
    ok, msg = litellm_set_budget(budget_id, amount)
    return ("done" if ok else "failed"), f"cancel -> {msg}"


def backoff_seconds(attempts: int) -> float:
    return min(900.0, 15.0 * (2 ** max(0, attempts - 1)))


# --------------------------------------------------------------------------- #
# receiver
# --------------------------------------------------------------------------- #

_READY = True


class Handler(BaseHTTPRequestHandler):
    server_version = "kb-bridge"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        LOG.debug("%s - %s", self.address_string(), fmt % args)

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # Kill Bill keeps the connection per-request; no keep-alive benefit.
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - stdlib signature
        if self.path.rstrip("/") == "/kb/health":
            self._send(200, {"ok": True, "ts": time.time()})
        else:
            self._send(404, {"ok": False})

    def do_POST(self):  # noqa: N802 - stdlib signature
        path = self.path.split("?", 1)[0].rstrip("/")

        # --- auth: secret lives in the path (Kill Bill can send no headers) ---
        expected = f"/kb/events/{PATH_TOKEN}" if PATH_TOKEN else "/kb/events"
        if not PATH_TOKEN or not hmac.compare_digest(path, expected):
            # 404, not 401 -- do not confirm the endpoint exists.
            self._send(404, {"ok": False})
            return

        # --- bound concurrency; shed rather than grow threads without limit ---
        if not _SLOTS.acquire(timeout=RECV_SLOT_WAIT_SECONDS):
            LOG.warning("at max concurrency (%s) after %.2fs -- shedding with 503",
                        MAX_CONCURRENT, RECV_SLOT_WAIT_SECONDS)
            self._send(503, {"ok": False, "error": "busy"})
            return
        try:
            self._handle_event()
        finally:
            _SLOTS.release()

    def _handle_event(self) -> None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send(400, {"ok": False, "error": "bad content-length"})
            return
        if length <= 0 or length > MAX_BODY:
            self._send(413, {"ok": False, "error": "body too large or empty"})
            return

        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8", "replace"))
            if not isinstance(payload, dict):
                raise ValueError("not an object")
        except Exception:  # noqa: BLE001 - store unparseable bodies too
            payload = {}

        # --- FAST PATH: persist and ACK. No business logic in the request. ---
        try:
            conn = db(busy_ms=RECV_BUSY_TIMEOUT_MS)
            try:
                fresh = enqueue(conn, payload, raw)
            finally:
                conn.close()
        except Exception as exc:  # noqa: BLE001
            # Non-2xx -> Kill Bill queues a retry. Failing FAST is the entire
            # point: waiting would park a Kill Bill event-bus thread (see
            # RECV_BUSY_TIMEOUT_MS).
            LOG.error("persist failed, returning 500 so Kill Bill retries: %s", exc)
            self._send(500, {"ok": False})
            return

        LOG.info(
            "recv eventType=%s objectId=%s accountId=%s fresh=%s",
            payload.get("eventType"), payload.get("objectId"), payload.get("accountId"), fresh,
        )
        self._send(200, {"ok": True, "duplicate": not fresh})


def run_receiver() -> int:
    global _READY
    init_db()

    def _stop(signum, _frame):
        global _READY
        LOG.info("signal %s -- shutting down receiver", signum)
        _READY = False

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    if not PATH_TOKEN:
        LOG.warning("KB_PATH_TOKEN is empty -- receiver will reject everything (fail-closed)")

    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True
    LOG.info("receiver listening on %s:%s  path=/kb/events/<token>  db=%s", BIND, PORT, DB_PATH)
    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        httpd.server_close()
    return 0


# --------------------------------------------------------------------------- #
# worker
# --------------------------------------------------------------------------- #

_WORK = True


def claim_batch(conn: sqlite3.Connection, limit: int) -> list[sqlite3.Row]:
    now = time.time()
    conn.execute("BEGIN IMMEDIATE")
    try:
        rows = conn.execute(
            "SELECT * FROM events WHERE status='pending' AND next_attempt_at<=? "
            "ORDER BY id LIMIT ?",
            (now, limit),
        ).fetchall()
        if rows:
            conn.executemany(
                "UPDATE events SET status='processing', attempts=attempts+1 WHERE id=?",
                [(r["id"],) for r in rows],
            )
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return rows


def run_worker() -> int:
    global _WORK
    init_db()

    def _stop(signum, _frame):
        global _WORK
        LOG.info("signal %s -- finishing current batch then exiting", signum)
        _WORK = False

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    if not LITELLM_KEY:
        LOG.error("FATAL: KB_LITELLM_MASTER_KEY is required for the worker")
        return 2

    LOG.info(
        "worker started  db=%s  litellm=%s  verify=%s  plan_default_duration=%s",
        DB_PATH, LITELLM_URL, VERIFY, BUDGET_DURATION or "(none)",
    )

    conn = db()
    idle_logged = False
    try:
        while _WORK:
            rows = claim_batch(conn, BATCH)
            if not rows:
                if not idle_logged:
                    LOG.debug("queue empty")
                    idle_logged = True
                time.sleep(POLL_SECONDS)
                continue
            idle_logged = False

            for row in rows:
                try:
                    status, msg = process_event(conn, row)
                except Exception as exc:  # noqa: BLE001
                    status, msg = "failed", f"{type(exc).__name__}: {exc}"

                if status == "failed":
                    attempts = row["attempts"] + 1
                    if attempts >= MAX_ATTEMPTS:
                        LOG.error("event id=%s gave up after %s attempts: %s",
                                  row["id"], attempts, msg)
                        conn.execute(
                            "UPDATE events SET status='failed', last_error=?, processed_at=?"
                            " WHERE id=?",
                            (msg[:500], time.time(), row["id"]),
                        )
                    else:
                        delay = backoff_seconds(attempts)
                        LOG.warning("event id=%s attempt %s failed (%s); retry in %.0fs",
                                    row["id"], attempts, msg[:160], delay)
                        conn.execute(
                            "UPDATE events SET status='pending', last_error=?, next_attempt_at=?"
                            " WHERE id=?",
                            (msg[:500], time.time() + delay, row["id"]),
                        )
                else:
                    LOG.info("event id=%s %s: %s", row["id"], status, msg[:200])
                    conn.execute(
                        "UPDATE events SET status=?, last_error=?, processed_at=? WHERE id=?",
                        (status, msg[:500], time.time(), row["id"]),
                    )
    finally:
        conn.close()
    return 0


# --------------------------------------------------------------------------- #
# sweep (reconciliation -- covers events that exhausted Kill Bill's retries)
# --------------------------------------------------------------------------- #


def run_sweep(once: bool = False) -> int:
    init_db()
    if not killbill_configured():
        # Inert-but-harmless: the timer is installed from day one and starts
        # doing real work the moment Kill Bill credentials are filled in.
        # Exit 0 so systemd does not mark the timer unit failed.
        LOG.warning(
            "sweep skipped: needs KB_KILLBILL_URL + api key/secret + user/password. "
            "Set them in kb-bridge.env once the .104 tenant exists."
        )
        return 0

    conn = db()
    try:
        while True:
            row = conn.execute(
                "SELECT v FROM meta WHERE k='sweep_last_invoice_number'"
            ).fetchone()
            try:
                watermark = float(row["v"]) if row else 0.0
            except (TypeError, ValueError):
                watermark = 0.0

            offset = 0
            pages = 0
            scanned = 0
            added = 0
            highest = watermark
            reached_end = False

            while pages < SWEEP_MAX_PAGES:
                # INVOICES, not payments. A Payment object has no `status` and no
                # `invoiceId` (verified against definitions/Payment), so the
                # earlier payment-based sweep silently matched nothing, forever.
                #
                # NO `audit` PARAM -- deliberately omitted.
                #
                # CORRECTED (2026-09-18): an earlier comment here claimed
                # "spec != implementation". That was WRONG. `audit` is not a
                # string, it is an enum:
                #     @QueryParam(QUERY_AUDIT) @DefaultValue("NONE") AuditMode
                # and AuditMode does AuditLevel.valueOf(str.toUpperCase()).
                # An invalid value throws during JAX-RS parameter conversion and
                # the spec REQUIRES a 404 for that. So the 404 was correct
                # behaviour, not a Kill Bill bug, and the param is usable as
                # audit=NONE|FULL|MINIMAL (all confirmed 200 live on .104).
                # We omit it because NONE is already the default.
                status, resp = http_json(
                    "GET",
                    f"{KILLBILL_URL}/1.0/kb/invoices/pagination?offset={offset}&limit=100",
                    None,
                    killbill_headers(),
                )
                if status != 200 or not isinstance(resp, list):
                    LOG.error("sweep fetch failed http=%s %s", status, str(resp)[:200])
                    break

                for inv in resp:
                    if not isinstance(inv, dict):
                        continue
                    scanned += 1
                    try:
                        num = float(inv.get("invoiceNumber"))
                    except (TypeError, ValueError):
                        num = 0.0
                    if num > highest:
                        highest = num
                    if num and num <= watermark:
                        continue  # already covered by an earlier sweep

                    # Invoice fields verified against the live swagger:
                    #   status  -> DRAFT | COMMITTED | VOID   (there is NO "PAID")
                    #   balance -> 0.0 once settled
                    if str(inv.get("status") or "").upper() != "COMMITTED":
                        continue
                    balance = inv.get("balance")
                    if balance is None or float(balance) > 0:
                        continue

                    synthetic = {
                        "eventType": ACTION_PAYMENT,
                        "objectType": "INVOICE",
                        "objectId": inv.get("invoiceId"),
                        "accountId": inv.get("accountId"),
                    }
                    raw = json.dumps(synthetic, sort_keys=True).encode()
                    if enqueue(conn, synthetic, raw, source="sweep"):
                        added += 1

                pages += 1
                if len(resp) < 100:
                    reached_end = True
                    break
                offset += 100

            if reached_end:
                conn.execute(
                    "INSERT INTO meta(k,v) VALUES('sweep_last_invoice_number',?) "
                    "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                    (str(highest),),
                )
                LOG.info(
                    "sweep complete: pages=%s scanned=%s new=%s watermark %.0f -> %.0f",
                    pages, scanned, added, watermark, highest,
                )
            else:
                # Truncated walk: do NOT advance the watermark. Advancing on a
                # partial scan would skip every invoice past the page cap
                # permanently. Re-scanning is cheap -- enqueue() de-duplicates.
                LOG.warning(
                    "sweep truncated at %s pages (max %s); watermark left at %.0f",
                    pages, SWEEP_MAX_PAGES, watermark,
                )

            if once:
                return 0
            time.sleep(SWEEP_INTERVAL_SECONDS)
    finally:
        conn.close()


# --------------------------------------------------------------------------- #
# status / admin
# --------------------------------------------------------------------------- #


def run_status() -> int:
    if not os.path.exists(DB_PATH):
        print(f"no database at {DB_PATH} -- run `init` first")
        return 1
    conn = db()
    try:
        print(f"db            : {DB_PATH}  ({os.path.getsize(DB_PATH)} bytes)")
        print(f"receiver      : {BIND}:{PORT}  path=/kb/events/<token>  token_set={bool(PATH_TOKEN)}")
        print(f"litellm       : {LITELLM_URL}  master_key_set={bool(LITELLM_KEY)}"
              f"  prefixed={LITELLM_KEY.startswith('sk-')}")
        print(f"verify        : {VERIFY}  killbill_configured={killbill_configured()}")
        print()
        print("events by status:")
        for r in conn.execute(
            "SELECT status, COUNT(*) c FROM events GROUP BY status ORDER BY status"
        ):
            print(f"   {r['status']:12} {r['c']}")
        print()
        print("recent events:")
        for r in conn.execute(
            "SELECT id,event_type,account_id,status,attempts,last_error FROM events"
            " ORDER BY id DESC LIMIT 10"
        ):
            print(f"   #{r['id']:<5} {str(r['event_type'])[:34]:34} "
                  f"{str(r['account_id'])[:20]:20} {r['status']:9} "
                  f"n={r['attempts']} {str(r['last_error'] or '')[:70]}")
        print()
        print("accounts:")
        rows = conn.execute("SELECT * FROM accounts ORDER BY account_id").fetchall()
        if not rows:
            print("   (none)")
        for r in rows:
            print(f"   {r['account_id'][:38]:38} budget={str(r['budget_id'])[:26]:26} "
                  f"plan={str(r['plan']):8} active={r['active']}")
        print()
        print("plans:")
        for r in conn.execute("SELECT * FROM plans ORDER BY plan_name"):
            print(f"   {r['plan_name']:12} budget={r['max_budget']:<10} "
                  f"on_cancel={r['on_cancel_budget']}")
        return 0
    finally:
        conn.close()


def run_map(args) -> int:
    init_db()
    conn = db()
    try:
        conn.execute(
            "INSERT INTO accounts(account_id,budget_id,key_alias,plan,active,note,updated_at)"
            " VALUES(?,?,?,?,?,?,?)"
            " ON CONFLICT(account_id) DO UPDATE SET budget_id=excluded.budget_id,"
            " key_alias=excluded.key_alias, plan=excluded.plan, active=excluded.active,"
            " note=excluded.note, updated_at=excluded.updated_at",
            (args.account_id, args.budget_id, args.key_alias, args.plan,
             0 if args.disable else 1, args.note, time.time()),
        )
        print(f"mapped account {args.account_id} -> budget {args.budget_id} "
              f"plan={args.plan} active={not args.disable}")
        return 0
    finally:
        conn.close()


def run_plan(args) -> int:
    init_db(seed=False)
    conn = db()
    try:
        conn.execute(
            "INSERT INTO plans(plan_name,max_budget,on_cancel_budget,updated_at)"
            " VALUES(?,?,?,?) ON CONFLICT(plan_name) DO UPDATE SET"
            " max_budget=excluded.max_budget, on_cancel_budget=excluded.on_cancel_budget,"
            " updated_at=excluded.updated_at",
            (args.plan_name, args.max_budget, args.on_cancel, time.time()),
        )
        print(f"plan {args.plan_name}: budget={args.max_budget} on_cancel={args.on_cancel}")
        return 0
    finally:
        conn.close()


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #


def main() -> int:
    p = argparse.ArgumentParser(description="Kill Bill -> LiteLLM budget bridge")
    p.add_argument("--log-level", default=os.environ.get("KB_LOG_LEVEL", "INFO"))
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("receiver")
    sub.add_parser("worker")
    sw = sub.add_parser("sweep")
    sw.add_argument("--once", action="store_true")
    sub.add_parser("init")
    sub.add_parser("status")

    m = sub.add_parser("map")
    m.add_argument("--account-id", required=True)
    m.add_argument("--budget-id", required=True)
    m.add_argument("--plan", default="basic")
    m.add_argument("--key-alias", default="")
    m.add_argument("--note", default="")
    m.add_argument("--disable", action="store_true")

    pl = sub.add_parser("plan")
    pl.add_argument("--plan-name", required=True)
    pl.add_argument("--max-budget", type=float, required=True)
    pl.add_argument("--on-cancel", type=float, default=0.0)

    args = p.parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)-7s %(name)s | %(message)s",
    )

    if args.cmd == "receiver":
        return run_receiver()
    if args.cmd == "worker":
        return run_worker()
    if args.cmd == "sweep":
        return run_sweep(once=args.once)
    if args.cmd == "init":
        init_db()
        print(f"initialised {DB_PATH}")
        return 0
    if args.cmd == "status":
        return run_status()
    if args.cmd == "map":
        return run_map(args)
    if args.cmd == "plan":
        return run_plan(args)
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
