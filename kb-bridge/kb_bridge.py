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
import socket
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
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
    """Read a config value, treating an EMPTY value as unset.

    Bug #155: `os.environ.get(name, default)` returns "" when the variable EXISTS
    but is blank -- the default is only used when the variable is absent. Every
    numeric config is then parsed with int()/float(), so one stray
    `KB_LEASE_SECONDS=` in the env file raised ValueError at import time and the
    bridge refused to start at all. The env file is hand-edited by whoever
    installs the box, so a blank value must fall back to the default rather than
    take the service down.
    """
    val = os.environ.get(name)
    if val is None or not val.strip():
        val = default
    if required and not (val or "").strip():
        LOG.error("FATAL: %s is required but not set", name)
        sys.exit(2)
    return (val or "").strip()


def cfg_bool(name: str, default: bool) -> bool:
    """Read a boolean, treating an EMPTY value as unset.

    Bug #155 (the dangerous half): an empty value used to fall through to
    `"" in ("1","true","yes","on")` == False. So a blank `KB_VERIFY=` turned
    verification OFF -- silently inverting a fail-CLOSED security control into a
    fail-OPEN one. A blank value must mean "unset", never "false".
    """
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


DB_PATH = cfg("KB_DB_PATH", "/opt/kb-bridge/kb-bridge.db")
BIND = cfg("KB_BIND", "0.0.0.0")
PORT = int(cfg("KB_PORT", "8555"))
PATH_TOKEN = os.environ.get("KB_PATH_TOKEN", "")
LITELLM_URL = cfg("KB_LITELLM_URL", "http://127.0.0.1:4000").rstrip("/")
LITELLM_KEY = os.environ.get("KB_LITELLM_MASTER_KEY", "")
BUDGET_DURATION = os.environ.get("KB_BUDGET_DURATION", "").strip()

# Kill Bill requires this header on every write. Kept as its own constant so the
# required-on-POST detail lives next to the other Kill Bill settings.
KB_CREATED_BY = os.environ.get("KB_CREATED_BY", "kb-bridge")
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
SWEEP_INTERVAL_SECONDS = float(cfg("KB_SWEEP_INTERVAL_SECONDS", "900"))

# Dunning notice (domain-email-and-go-to-market-strategy.md §2.8): the bridge
# sends the overdue warning itself -- one HTTP call to Resend. Best-effort: a
# missing key means "skip the email, never crash", and the cut-off (OD2/OD3) is
# independent of the notice. Emails go to RESELLERS only (the account's email).
RESEND_API_KEY = cfg("KB_RESEND_API_KEY", "")
RESEND_FROM = cfg("KB_RESEND_FROM", "Custodian Billing <invoices@billing.custodian.work>")
RESEND_SUBJECT = cfg("KB_RESEND_SUBJECT", "Action needed: your Custodian payment is overdue")

# --- worker lease (Bug #150) ----------------------------------------------- #
# Claiming a row is "borrowing it for a fixed period", never permanent ownership.
# If the worker dies between the claim and the status update (SIGKILL, OOM kill
# under MemoryMax, power loss) the lease expires and the row is reclaimed. That
# is the ONLY thing that makes a claimed-but-abandoned payment recoverable;
# without it `status='processing'` is a terminal state nothing ever leaves.
# LEASE_SECONDS must comfortably exceed the worst case for ONE row (bounded by
# HTTP_TIMEOUT); the worker also renews it while working through a batch.
LEASE_SECONDS = float(cfg("KB_LEASE_SECONDS", "600"))
REAP_BATCH = int(cfg("KB_REAP_BATCH", "100"))
WORKER_OWNER = f"{socket.gethostname()}:{os.getpid()}"

# --- sweep scope (Bug #151 -> Bug #157) ------------------------------------ #
# Bug #157 replaced the byNumber walk with the documented balance search, so
# this is now a PAGE budget, not an invoice-number budget. 20 pages x 200 per
# page = 4,000 invoices examined per run.
#
# It is deliberately a page cap and not a generous number cap: if it is ever hit
# the run logs a WARNING saying coverage was NOT complete. Bug #151's lesson was
# that a walk can go blind silently -- so the one way to be blind here is made
# visible instead of made unlikely.
SWEEP_PAGE_SIZE = int(cfg("KB_SWEEP_PAGE_SIZE", "200"))
SWEEP_MAX_PAGES = int(cfg("KB_SWEEP_MAX_PAGES", "20"))

# URL-encoded `_q=1&balance[lte]=0` -- the documented balance search
# (`GET /1.0/kb/invoices/search/{searchKey}`). Verified live against 0.24.21.
# URL-encoding is REQUIRED (killbill.github.io/slate/invoice.html): `[` -> %5B,
# `]` -> %5D, `%` -> %25. `&` and `=` are encoded too so the whole search key
# stays ONE url path segment; JAX-RS decodes it back before the DAO sees it.
#
# `lte` and not `eq`: a fully-paid invoice has balance exactly 0, but an OVERPAID
# one can be negative, and the SQL zeroes DRAFT/VOID/migrated/written-off rows --
# all of which would be missed by `eq`. They are then rejected by the guards in
# _sweep_consider_invoice (needs status COMMITTED + a SUCCESS PURCHASE payment),
# so the superset costs a little work and cannot produce a false grant.
SWEEP_BALANCE_QUERY = "_q%3D1%26balance%5Blte%5D%3D0"
# The INVERSE of the sweep query: invoices that still carry a balance, i.e. unpaid.
# Used to corroborate a cut-off before acting on it. `gt` is the operator that
# works on 0.24.21 -- `gte` returns a 500 SQL error. Both verified live.
UNPAID_BALANCE_QUERY = "_q%3D1%26balance%5Bgt%5D%3D0"

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

# Per-connection socket timeout. WITHOUT this, a peer that promises a
# Content-Length and then stalls holds its handler thread forever: the handler
# blocks in rfile.read(), server_close() joins it forever, the unit hits
# TimeoutStopSec and systemd SIGKILLs us -- the exact symptom of Bug #158, back
# again. It also stops one stalled connection from sitting on a concurrency slot
# indefinitely. Handlers here take single-digit milliseconds, so 5 s is generous.
RECV_SOCKET_TIMEOUT_SECONDS = float(cfg("KB_RECV_SOCKET_TIMEOUT_SECONDS", "5"))
# Hard ceiling on the post-signal drain. server_close() joins in-flight handlers
# with no timeout of its own, and a client that dribbles one byte at a time can
# outlive any per-read timeout, so the drain also needs an absolute deadline.
# MUST stay comfortably below the unit's TimeoutStopSec (10 s).
DRAIN_BUDGET_SECONDS = float(cfg("KB_DRAIN_BUDGET_SECONDS", "3"))

# Event types we act on. Anything else is acknowledged and marked 'skipped'.
ACTION_PAYMENT = "INVOICE_PAYMENT_SUCCESS"
ACTION_CANCEL = ("SUBSCRIPTION_CANCEL", "SUBSCRIPTION_EXPIRED")

# --------------------------------------------------------------------------- #
# Phase 2 — top-ups
# --------------------------------------------------------------------------- #
# The fee lives ON TOP of the token value, per pricing/reseller-pricing-model.md §2:
#   "When a reseller reloads tokens, we charge 15% on top ... reseller reloads
#    $10.00 of tokens -> pays $11.50"   (5% processing + 10% us)
# So the credit the customer receives is what they PAID divided by 1.15. The
# mapping lives here, once, and is never itemised in anything the reseller sees
# (the One Rule: one blended price).
TOPUP_FEE_DIVISOR = 1.15

# Written into the Kill Bill invoice item so a paid top-up can be told apart from
# a subscription payment. A catalog plan cannot express an arbitrary amount
# ("one-time, min $10, no max"), so a top-up is created as an EXTERNAL CHARGE and
# this string rides in the item's itemDetails.
TOPUP_MARKER = "CUSTODIAN_TOPUP"

# Kill Bill's built-in bookkeeping plugin. It exists to record money that arrived
# OUTSIDE Kill Bill, so a payment it records proves nothing about money -- and the
# engine also reaches for it when an account's default payment method is not a
# real gateway. Only a real gateway plugin settling a confirmed charge is revenue.
BOOKKEEPING_PLUGIN = "__EXTERNAL_PAYMENT__"

# Minimum top-up, in TOKENS (the amount credited), per the build plan:
# "one-time, min $10, no max". The charge is 1.15x this.
MIN_TOPUP_TOKENS = 10.0

# --------------------------------------------------------------------------- #
# Phase 3 — the cut-off (Bug #154 / GitHub #142)
# --------------------------------------------------------------------------- #
# THE HARD REQUIREMENT (Neo, 2026-09-22, domain-email-and-go-to-market-strategy.md
# §2.8): "So long as we can cut services when payment is missing that's all that
# matters. From both debit/credit AND crypto." A gate, not a preference.
#
# The trigger is "is the invoice paid", never "how did they pay", so ONE mechanism
# covers cards AND crypto.
#
# Kill Bill's Overdue System owns the POLICY (the ladder is configured per tenant
# from kb-bridge/overdue-custodian.xml); the bridge only reacts to the resulting
# state change. The rule therefore lives in ONE place, not two.
#
# These are OUR state names, from that config -- not invented here:
#   CUST_OD1_WARNING  day 7+   blockChanges only, entitlement NOT disabled
#   CUST_OD2_BLOCKED  day 14+  disableEntitlement  -> kill the AI budget
#   CUST_OD3_CANCEL   day 30+  disableEntitlement + END_OF_TERM cancel
#   CLEAR             synthesised internally once nothing matches (i.e. they paid)
#
# Verified from the REAL event payloads captured live on VM205 (events 335/336):
#   {"eventType":"BLOCKING_STATE","accountId":"…","objectType":"ACCOUNT",
#    "objectId":"…","metaData":"{\"blockableId\":\"…\",\"service\":\"overdue-service\",
#    \"stateName\":\"CUST_OD1_WARNING\",\"blockingType\":\"ACCOUNT\",…}"}
# NOTE: `metaData` arrives as a JSON **STRING**, not an object -- it must be parsed
# a second time. That is the single easiest thing to get wrong here.
ACTION_BLOCK = ("BLOCKING_STATE",)
OVERDUE_WARN_STATE = "CUST_OD1_WARNING"
OVERDUE_BLOCK_STATES = ("CUST_OD2_BLOCKED", "CUST_OD3_CANCEL")
OVERDUE_CLEAR_STATE = "CLEAR"

# A failed payment is RECORDED, never acted on. The dunning policy belongs to the
# overdue ladder above (OD1 warn -> OD2 cut -> OD3 cancel), so the bridge must not
# invent a second one. Bug #154's entry says exactly this.
ACTION_PAYMENT_FAILED = "INVOICE_PAYMENT_FAILED"

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
    processed_at    REAL,
    -- lease fields (Bug #150): a claim is a time-boxed borrow, not ownership.
    -- lease_expires_at is epoch seconds (REAL) -- never a formatted string.
    lease_token     TEXT,
    lease_expires_at REAL,
    owner           TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ready ON events(status, next_attempt_at);
-- the reclaim query path: status + expiry (Bug #150)
CREATE INDEX IF NOT EXISTS idx_events_lease ON events(status, lease_expires_at);

CREATE TABLE IF NOT EXISTS accounts (
    account_id TEXT PRIMARY KEY,
    budget_id  TEXT,
    key_alias  TEXT,
    -- sha256 hex of the customer's LiteLLM key (LiteLLM's hash_token). Needed to
    -- reset a key's accrued spend on payment (Bug #156 follow-up): LiteLLM has
    -- no way to look a key up by budget_id or alias, so we must store it.
    -- NEVER store the plaintext key here.
    litellm_key_hash TEXT,
    plan       TEXT,
    -- ---- Top-up ledger (Phase 2) -------------------------------------------- #
    -- A top-up RAISES the ceiling; it does not grant a new period. The plan
    -- allowance is consumed FIRST, so top-up credit only starts burning once
    -- real spend passes plan_budget. See the top-up policy note in
    -- kb-bridge/README.md.
    --   ceiling = plan_budget + (topup_granted - topup_committed)
    -- topup_committed is advanced only at a PERIOD BOUNDARY, because a period's
    -- own consumption must not shrink the ceiling it is being spent against.
    plan_budget     REAL,
    topup_granted   REAL NOT NULL DEFAULT 0,
    topup_committed REAL NOT NULL DEFAULT 0,
    -- Value of the LiteLLM budget_reset_at we last saw: a change means the
    -- calendar reset fired and the period rolled.
    period_anchor   TEXT,
    -- Last observed spend. Read just before a reset so the consumption that
    -- closed the period can be committed to the ledger.
    last_spend      REAL NOT NULL DEFAULT 0,
    active     INTEGER NOT NULL DEFAULT 1,
    note       TEXT,
    -- Which rail actually collects this account's money.
    --   'card'   = Kill Bill auto-charges the saved Stripe payment method. A
    --              payment recorded through the __EXTERNAL_PAYMENT__ bookkeeping
    --              plugin is therefore NOT money, and the bridge refuses it.
    --   'manual' = crypto/offline: a payment is recorded by hand only AFTER the
    --              gateway confirms it, so bookkeeping payments ARE credited.
    -- Default is the safe one: refuse anything that is not a real rail.
    rail       TEXT NOT NULL DEFAULT 'card',
    updated_at REAL
);

-- One row per top-up invoice, holding the credit granted so far. This is what
-- makes the grant IDEMPOTENT and partial-payment-correct: the entitlement is
-- recomputed from the amount actually PAID on the invoice, and only the DELTA is
-- added to the ledger. So a duplicated event grants 0 (instead of granting the
-- whole credit again), and a second instalment grants only the remainder.
CREATE TABLE IF NOT EXISTS topup_grants (
    invoice_id  TEXT PRIMARY KEY,
    account_id  TEXT NOT NULL,
    paid        REAL NOT NULL DEFAULT 0,
    item_total  REAL NOT NULL DEFAULT 0,
    credit      REAL NOT NULL DEFAULT 0,
    updated_at  REAL
);

CREATE TABLE IF NOT EXISTS plans (
    plan_name        TEXT PRIMARY KEY,
    max_budget       REAL NOT NULL,
    on_cancel_budget REAL NOT NULL DEFAULT 0,
    updated_at       REAL
);

CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
"""


_SCHEMA_READY = False


def _migrate(conn: sqlite3.Connection) -> None:
    """Bring an existing database up to the current schema. Idempotent.

    CREATE TABLE IF NOT EXISTS is a no-op on an existing table, so purely
    additive changes never reach a deployed database. That is exactly how a
    schema change silently ships broken: the fresh install works and the running
    box does not. Additive migrations are applied here, once per process.
    """
    global _SCHEMA_READY
    if _SCHEMA_READY:
        return
    exists = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='events'"
    ).fetchone()
    if not exists:
        return  # init_db() will create it with the full schema
    have = {r["name"] for r in conn.execute("PRAGMA table_info(events)")}
    for col, decl in (
        ("lease_token", "TEXT"),
        ("lease_expires_at", "REAL"),
        ("owner", "TEXT"),
    ):
        if col not in have:
            LOG.info("migrating: adding events.%s", col)
            conn.execute(f"ALTER TABLE events ADD COLUMN {col} {decl}")  # noqa: S608 - fixed literals
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_events_lease ON events(status, lease_expires_at)"
    )
    # accounts also gains columns over time. Migrating here (not only in init_db)
    # means a plain receiver/worker start brings the schema up to date, so an
    # upgrade cannot silently run against the old shape.
    acols = {r["name"] for r in conn.execute("PRAGMA table_info(accounts)")}
    if acols:
        for col, decl in (
            ("litellm_key_hash", "TEXT"),
            ("plan_budget", "REAL"),
            ("topup_granted", "REAL NOT NULL DEFAULT 0"),
            ("topup_committed", "REAL NOT NULL DEFAULT 0"),
            ("period_anchor", "TEXT"),
            ("last_spend", "REAL NOT NULL DEFAULT 0"),
            ("rail", "TEXT NOT NULL DEFAULT 'card'"),
        ):
            if col not in acols:
                LOG.info("migrating: adding accounts.%s", col)
                conn.execute(f"ALTER TABLE accounts ADD COLUMN {col} {decl}")  # noqa: S608 - fixed literals
    _SCHEMA_READY = True


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
    _migrate(conn)
    return conn


def init_db(seed: bool = True) -> None:
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = db()
    try:
        conn.executescript(SCHEMA)
        # CREATE TABLE IF NOT EXISTS does NOT add columns to a table that already
        # exists, so new columns need an explicit idempotent ALTER here.
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(accounts)")}
        if "litellm_key_hash" not in cols:
            conn.execute("ALTER TABLE accounts ADD COLUMN litellm_key_hash TEXT")
            LOG.info("migrated accounts: added litellm_key_hash")
        # Phase 2 top-up ledger. Same trap, same idempotent fix.
        for col, decl in (
            ("plan_budget", "REAL"),
            ("topup_granted", "REAL NOT NULL DEFAULT 0"),
            ("topup_committed", "REAL NOT NULL DEFAULT 0"),
            ("period_anchor", "TEXT"),
            ("last_spend", "REAL NOT NULL DEFAULT 0"),
            ("rail", "TEXT NOT NULL DEFAULT 'card'"),
        ):
            if col not in cols:
                conn.execute(f"ALTER TABLE accounts ADD COLUMN {col} {decl}")  # noqa: S608
                LOG.info("migrated accounts: added %s", col)
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


def http_json_hdrs(method: str, url: str, body: dict | list | None = None, headers: dict | None = None,
                   timeout: float = HTTP_TIMEOUT) -> tuple[int, dict | list | str, dict]:
    """Same as http_json but also returns the response headers.

    Exists because Kill Bill's pagination contract is expressed in HEADERS
    (`X-Killbill-Pagination-NextOffset`, `-TotalNbRecords`), and the sweep needs
    them to know when it has reached the end of a result set. Kept as a separate
    function so http_json keeps its 2-tuple contract and none of its existing
    callers change.
    """
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Content-Type": "application/json", "Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            got = dict(resp.headers)
            try:
                return resp.status, json.loads(raw) if raw else {}, got
            except json.JSONDecodeError:
                return resp.status, raw, got
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        got = dict(exc.headers) if exc.headers else {}
        try:
            return exc.code, json.loads(raw), got
        except json.JSONDecodeError:
            return exc.code, raw, got
    except Exception as exc:  # noqa: BLE001 - network layer, we want the message
        return 0, f"{type(exc).__name__}: {exc}", {}


def http_json(method: str, url: str, body: dict | list | None = None, headers: dict | None = None,
              timeout: float = HTTP_TIMEOUT) -> tuple[int, dict | list | str]:
    status, parsed, _ = http_json_hdrs(method, url, body, headers, timeout)
    return status, parsed


def litellm_headers() -> dict:
    return {"Authorization": f"Bearer {LITELLM_KEY}"}


def litellm_set_budget(budget_id: str, max_budget: float, key_ref: str = "") -> tuple[bool, str]:
    """Set a customer's ceiling, ON THE KEY, and return (ok, message).

    The ceiling must be written where the enforcer actually reads it. Verified
    live against v1.95.0 (A/B/C probe, 2026-09-29):

      * a key created with a `budget_id` and NO own `max_budget` IS blocked at
        the linked budget object's value, because
        `LiteLLM_VerificationTokenView.__init__` copies `litellm_budget_table_*`
        onto the token -- but only `if current is None`;
      * a key that carries its OWN `max_budget` is blocked at the KEY's value
        and the linked budget object is IGNORED entirely.

    Our provisioning path (`setup-custodian-factory.sh:39`) creates keys WITH
    their own `max_budget`, and nothing in the repo ever links them to a budget
    object. So writing `/budget/update` for a normal customer key moves an
    object that nothing enforces -- the top-up would silently do nothing.

    Therefore the KEY is the single source of truth. `/key/update` accepts the
    sha256 hash we store (`_hash_token_if_needed` hashes only `sk-` values) and
    `prepare_key_update_data` uses `model_dump(exclude_unset=True)`, so fields we
    do not send (e.g. the `budget_duration` set at provisioning) are preserved.

    The budget-object write is kept as the fallback for an account with no key
    hash, so nothing that used to work stops working. Neither target is
    mandatory on its own: provisioning creates keys that carry their own
    ceiling and are linked to NO budget object, so a mapping with a key hash
    and a NULL budget_id is a normal, fully-working account (2026-09-29).
    """
    key_ref = (key_ref or "").strip()
    if not key_ref and not (budget_id or "").strip():
        return False, "no key hash and no budget_id - nowhere to write the ceiling"
    if key_ref:
        status, resp = http_json(
            "POST", f"{LITELLM_URL}/key/update",
            {"key": key_ref, "max_budget": max_budget}, litellm_headers(),
        )
        if status == 200:
            return True, f"updated key max_budget={max_budget}"
        LOG.warning(
            "key/update failed (%s): %s -- falling back to budget object %s",
            status, str(resp)[:200], budget_id,
        )
        # If there is no budget object to fall back to, STOP. Without this the
        # code below posts `budget_id: null` and LiteLLM CREATES a junk budget
        # row with a random uuid -- a blind object that nothing enforces. A
        # failed key write must be a visible failure, never a quiet write
        # somewhere harmless (observed live 2026-09-29).
        if not (budget_id or "").strip():
            return False, (
                f"key/update failed ({status}) and the mapping has no budget_id to "
                f"fall back to - ceiling NOT set. {str(resp)[:160]}"
            )

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


def litellm_key_state(key_ref: str) -> tuple[bool, dict | str]:
    """GET /key/info -> everything the top-up ledger needs, in ONE call.

    Verified live against v1.95.0: `/key/info` is a **GET** with a query param
    (a POST returns 405), and a single response carries BOTH the key's own `spend`
    and the linked budget's `max_budget` / `budget_duration` / `budget_reset_at`
    under `litellm_budget_table`. Accepts the plaintext key or its sha256 hash
    (`_hash_token_if_needed` hashes only `sk-`-prefixed values).
    """
    url = f"{LITELLM_URL}/key/info?key={urllib.parse.quote(key_ref, safe='')}"
    status, resp = http_json("GET", url, None, litellm_headers())
    if status != 200 or not isinstance(resp, dict):
        return False, f"key/info http={status} {str(resp)[:160]}"
    info = resp.get("info") or {}
    bt = info.get("litellm_budget_table") or {}
    return True, {
        "spend": float(info.get("spend") or 0.0),
        # The ceiling READ must match the WRITE target (see litellm_set_budget):
        # the key's own value wins whenever it is set, because that is what the
        # enforcer reads. Falling back to the budget object keeps the effective
        # value correct for a key that carries no ceiling of its own.
        #
        # `is not None` and not truthiness: 0.0 is a legitimate ceiling and must
        # not be mistaken for "unset".
        "max_budget": (
            info.get("max_budget")
            if info.get("max_budget") is not None
            else bt.get("max_budget")
        ),
        "budget_duration": bt.get("budget_duration", info.get("budget_duration")),
        "budget_reset_at": bt.get("budget_reset_at", info.get("budget_reset_at")),
        "budget_id": info.get("budget_id") or bt.get("budget_id"),
    }


def litellm_reset_spend(key_ref: str, reset_to: float = 0.0) -> tuple[bool, str]:
    """Clear a customer key's accrued spend so a payment actually unblocks them.

    Bug #156 follow-up. `max_budget` is a CEILING, not an allowance: LiteLLM
    blocks on `spend >= max_budget`, and /budget/update accepts no `spend` field
    at all (verified in v1.95.0), so raising the ceiling can never empty the
    meter. A customer who burned their allowance, got cut off and then PAID
    therefore stayed blocked until the monthly reset.

    This is the endpoint that does empty it. Verified live against v1.95.0:
      POST /key/{key}/reset_spend {"reset_to": 0}
      -> 200 {"spend": 0.0, "previous_spend": 0.42, "max_budget": 1.0, ...}
    It also rewrites the proxy's spend counter cache, so the change takes effect
    immediately rather than on the next counter refresh.

    key_ref is either the plaintext `sk-...` key or its sha256 hex (LiteLLM's
    `hash_token`). We store the hash, so the plaintext key is never needed here.
    `reset_to` must be >= 0 and <= the current spend, so 0.0 is always safe and
    the call is idempotent.
    """
    status, resp = http_json(
        "POST", f"{LITELLM_URL}/key/{key_ref}/reset_spend",
        {"reset_to": reset_to}, litellm_headers(),
    )
    if status == 200 and isinstance(resp, dict):
        return True, (
            f"spend reset {resp.get('previous_spend')} -> {resp.get('spend')}"
        )
    return False, f"key/reset_spend http={status} {str(resp)[:200]}"


def litellm_set_blocked(key_ref: str, blocked: bool) -> tuple[bool, str]:
    """Block or unblock a customer's key. Returns (ok, message).

    Phase 3 cut-off. `POST /key/block` and `/key/unblock` both take
    `{"key": <sk-... or sha256 hex>}`, so the stored hash is sufficient and the
    plaintext key is never needed.

    WHY THIS AND NOT A CEILING CHANGE: the source (v1.95.0
    key_management_endpoints.py:6029-6039) writes `blocked: True` and then calls
    `_delete_cache_key_object(...)`, explicitly invalidating the key cache. The
    change therefore takes effect on the NEXT request. A ceiling edit does not --
    the proxy caches a key's budget for up to 60 s, which is why the cut-off must
    not be expressed as `max_budget = 0`.

    It is also reversible in one call, which is what "restore when they pay" needs.
    """
    if not key_ref:
        return False, "no key reference for block/unblock"
    route = "/key/block" if blocked else "/key/unblock"
    status, resp = http_json(
        "POST", f"{LITELLM_URL}{route}", {"key": key_ref}, litellm_headers()
    )
    if status == 200:
        return True, f"{route}: ok"
    return False, f"{route} http={status} {str(resp)[:200]}"


def killbill_verify_account_overdue(account_id: str) -> tuple[bool, str]:
    """Is this account genuinely carrying an unpaid invoice? Fail closed.

    The cut-off is the most damaging thing this bridge can do, so it gets the same
    corroboration a payment or a cancellation gets (Bug #153's principle: the
    callback path token is a noise filter, not authentication -- `BLOCKING_STATE`
    arrives on that same unauthenticated path).

    Corroborating the *reason* beats reading back the state: if no unpaid invoice
    exists there is nothing to cut for, and the event is refused.

    Syntax verified LIVE against KB 0.24.21, not assumed:
      `balance[gt]=0`      -> 200, the unpaid invoices
      `balance[lte]=0`     -> 200, the settled ones  (already used by the sweep)
      `balance[gte]=0.01`  -> 500, java.sql.SQLSyntaxErrorException -- NOT supported
    """
    if not killbill_configured():
        return False, "killbill credentials not configured (fail-closed)"
    if not account_id:
        return False, "event carried no accountId"

    url = (
        f"{KILLBILL_URL}/1.0/kb/invoices/search/{UNPAID_BALANCE_QUERY}"
        "?offset=0&limit=200"
    )
    status, resp = http_json("GET", url, None, killbill_headers())
    if status != 200 or not isinstance(resp, list):
        return False, f"unpaid-invoice search http={status} {str(resp)[:160]}"

    mine = [i for i in resp if (i.get("accountId") or "") == account_id]
    if not mine:
        return False, "no unpaid invoice for this account -- refusing to cut"
    total = sum(float(i.get("balance") or 0.0) for i in mine)
    if total <= 0:
        return False, "unpaid invoices carry no balance -- refusing to cut"
    return True, f"verified: {len(mine)} unpaid invoice(s), balance {total:.2f}"


def killbill_headers() -> dict:
    h = {"Accept": "application/json"}
    if KB_API_KEY:
        h["X-Killbill-ApiKey"] = KB_API_KEY
    if KB_API_SECRET:
        h["X-Killbill-ApiSecret"] = KB_API_SECRET
    if KB_USER and KB_PASSWORD:
        token = base64.b64encode(f"{KB_USER}:{KB_PASSWORD}".encode()).decode()
        h["Authorization"] = f"Basic {token}"
    # Kill Bill REQUIRES X-Killbill-CreatedBy on writes; without it a POST fails
    # with `Header X-Killbill-CreatedBy needs to be set` (found by running the
    # top-up path: the GET-only callers never needed it). Harmless on reads.
    h["X-Killbill-CreatedBy"] = KB_CREATED_BY
    return h


def killbill_configured() -> bool:
    return bool(KILLBILL_URL and KB_API_KEY and KB_API_SECRET and KB_USER and KB_PASSWORD)


def killbill_account_email(account_id: str) -> tuple[bool, str, str, bool]:
    """Fetch a reseller account's email from Kill Bill. Returns (ok, email, why, retryable).

    §2.8: dunning notices go to RESELLERS only, and the account carries the
    address (`email` + `locale`). The bridge's own `accounts` table has no email
    column, so this is fetched on demand rather than stored.

    `retryable` distinguishes a TRANSIENT fetch failure (Kill Bill hiccup /
    replication lag) -- worth retrying -- from a PERMANENT one (no email / not
    configured) -- retrying cannot conjure an address.
    """
    if not killbill_configured():
        return False, "", "Kill Bill is not configured", False
    url = f"{KILLBILL_URL}/1.0/kb/accounts/{account_id}"
    status, data, _ = http_json_hdrs("GET", url, None, killbill_headers())
    if status != 200:
        # Kill Bill just emitted an event for this account, so a non-200 here is
        # a transient inconsistency (hiccup / replication lag), not a permanent
        # state. Worth retrying.
        return False, "", f"GET account -> {status}", True
    email = ""
    if isinstance(data, dict):
        email = (data.get("email") or "").strip()
    if not email:
        return False, "", f"account {account_id} has no email", False
    return True, email, "", False


def send_dunning_email(to_email: str, subject: str, body_html: str,
                       idempotency_key: str = "") -> tuple[bool, str]:
    """Send one dunning notice via the Resend API. Returns (ok, message).

    Best-effort by design: the caller decides whether to retry. Never raises --
    a bad key, a timeout, or a 4xx/5xx is returned as (False, why) so the worker
    can log it and keep the queue moving.

    `idempotency_key` is passed through as Resend's `Idempotency-Key` header:
    a retry of the same logical notice (same key) is deduped by Resend within
    24h, so a timeout that actually delivered won't re-send a duplicate.
    """
    if not RESEND_API_KEY:
        return False, "KB_RESEND_API_KEY is not configured"
    payload = json.dumps(
        {"from": RESEND_FROM, "to": [to_email], "subject": subject, "html": body_html}
    ).encode()
    hdrs = {
        "Authorization": "Bearer " + RESEND_API_KEY,
        "Content-Type": "application/json",
        "Accept": "application/json",
        # api.resend.com sits behind Cloudflare; urllib's default UA is
        # 403-blocked ("error code: 1010"). A real UA is required.
        "User-Agent": "Custodian-kb-bridge/1.0",
    }
    if idempotency_key:
        hdrs["Idempotency-Key"] = idempotency_key
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=payload,
        method="POST",
        headers=hdrs,
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", "replace")
            mid = ""
            try:
                mid = json.loads(raw).get("id", "")
            except Exception:  # noqa: BLE001 - body may not be JSON
                mid = ""
            return True, ("resend 200" + (f" id={mid}" if mid else ""))
    except urllib.error.HTTPError as exc:
        return False, f"resend HTTP {exc.code}"
    except Exception as exc:  # noqa: BLE001 - timeout/conn refused are all "not sent"
        return False, f"resend error: {exc}"


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


def killbill_verify_subscription_ended(account_id: str, subscription_id: str) -> tuple[bool, str]:
    """Re-verify a claimed cancellation against Kill Bill. Fail closed.

    Bug #153: the cancellation path used to "verify" nothing but the presence of
    credentials, so ANY request carrying the callback path token could zero a
    paying customer's budget (on_cancel_budget=0.0 for every seeded plan). The
    path token is documented in this file as a noise filter, not authentication,
    so it must not be the only control on a destructive action.

    The official Kill Bill push-notification docs state the contract plainly:
    "it is expected that your handler calls back the Kill Bill APIs to retrieve
    the latest state of the objects before acting upon it."

    `state` values come from the engine's Subscription definition; the ones that
    mean "this entitlement is over" are CANCELLED and EXPIRED.
    """
    if not killbill_configured():
        return False, "killbill credentials not configured (fail-closed)"
    if not subscription_id:
        return False, "event carried no subscription id to verify"

    status, resp = http_json(
        "GET",
        f"{KILLBILL_URL}/1.0/kb/subscriptions/{subscription_id}",
        None,
        killbill_headers(),
    )
    if status == 200 and isinstance(resp, dict):
        owner = resp.get("accountId")
        if owner and account_id and owner != account_id:
            return False, "subscription does not belong to the claimed account"
        state = str(resp.get("state") or "").upper()
        if state in ("CANCELLED", "EXPIRED"):
            return True, f"verified: subscription state={state}"
        return False, f"subscription has not ended (state={state or 'missing'}) - refusing"

    if status == 404:
        # The subscription is gone entirely; there is no entitlement left to keep
        # a budget for.
        return True, "verified: subscription no longer exists (404)"

    return False, f"subscription lookup http={status} {str(resp)[:140]}"


# --------------------------------------------------------------------------- #
# Event -> action
# --------------------------------------------------------------------------- #


def killbill_invoice(invoice_id: str) -> tuple[bool, str, dict]:
    """Fetch one invoice and return (ok, reason, invoice).

    The push payload carries only five fields -- no amount, no item detail -- so a
    payment CANNOT be classified without asking the engine what was paid for. The
    invoice document carries the three things this path needs: the items (what was
    bought), `amount`, and `balance` -- and balance is computed in SQL as
    SUM(items) - SUM(successful payments + refunds), so `amount - balance` is the
    amount actually PAID. That is the only honest basis for a credit.

    Uses the same endpoint/URL form as `killbill_verify_invoice_paid`, which has
    already fetched this object once for its own fail-closed checks (ownership,
    COMMITTED, balance 0). The two are kept separate on purpose: the verify path
    is a security control with its own carefully-earned comments, and this helper
    must not change its behaviour.
    """
    if not killbill_configured():
        return False, "Kill Bill not configured", {}
    if not invoice_id:
        return False, "no invoice id to fetch", {}
    status, resp = http_json(
        "GET", f"{KILLBILL_URL}/1.0/kb/invoices/{invoice_id}", None, killbill_headers()
    )
    if status != 200 or not isinstance(resp, dict):
        return False, f"invoice fetch http={status} {str(resp)[:160]}", {}
    if not isinstance(resp.get("items"), list):
        return False, "invoice has no item list", {}
    return True, "ok", resp


def _float_or_none(val) -> float | None:
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def classify_invoice(account_id: str, invoice_id: str) -> tuple[bool, bool, str, dict]:
    """Return (lookup_ok, is_topup, reason, money).

    `money` carries `item_total` (the top-up line itself) and `paid` (what was
    actually settled on the invoice).

    A top-up is identified by TOPUP_MARKER in the item's `itemDetails`, falling
    back to `description`. Everything else on the account is a subscription
    payment.

    lookup_ok is SEPARATE from is_topup on purpose: a failed lookup must fail the
    event rather than be silently read as "subscription payment", which would set
    the ceiling to the plan value and quietly erase a customer's top-up credit.
    """
    ok, why, inv = killbill_invoice(invoice_id)
    if not ok:
        return False, False, why, {}
    items = inv.get("items") or []
    amount = _float_or_none(inv.get("amount")) or 0.0
    balance = _float_or_none(inv.get("balance")) or 0.0
    # `amount - balance` is the settled part (balance is SQL: SUM(items) minus
    # SUM(successful payments + refunds)). Callers cap the credit against
    # item_total, so an overpayment can never buy more than was sold.
    paid = round(amount - balance, 6)
    for it in items:
        blob = f"{it.get('itemDetails') or ''} {it.get('description') or ''}"
        if TOPUP_MARKER in blob:
            item_total = _float_or_none(it.get("amount"))
            if item_total is None:
                return True, False, "top-up item has a non-numeric amount", {}
            return True, True, (
                f"top-up item {it.get('invoiceItemId')} charge={item_total} paid={paid}"
            ), {"item_total": item_total, "paid": paid}
    return True, False, "no top-up marker (subscription payment)", {"paid": paid}


# --------------------------------------------------------------------------- #
# Top-up ledger
# --------------------------------------------------------------------------- #
# ceiling = plan allowance + UNCONSUMED top-up credit
# The plan allowance is consumed first, so top-up credit only starts burning once
# real spend passes plan_budget. Consumption is committed to the ledger only at a
# PERIOD BOUNDARY: shrinking the ceiling mid-period while spend climbs would
# subtract the same dollars twice.


def account_plan_budget(conn: sqlite3.Connection, acct: sqlite3.Row) -> float:
    """The plan baseline for an account, derived from `plans` when unset."""
    if acct["plan_budget"] is not None:
        return float(acct["plan_budget"])
    prow = conn.execute(
        "SELECT max_budget FROM plans WHERE plan_name=?", (acct["plan"],)
    ).fetchone()
    base = float(prow["max_budget"]) if prow else 0.0
    conn.execute(
        "UPDATE accounts SET plan_budget=?, updated_at=? WHERE account_id=?",
        (base, time.time(), acct["account_id"]),
    )
    LOG.info("backfilled plan_budget=%.6f for account %s", base, acct["account_id"])
    return base


def topup_ceiling(acct: sqlite3.Row, plan_budget: float) -> float:
    granted = float(acct["topup_granted"] or 0.0)
    committed = float(acct["topup_committed"] or 0.0)
    return round(plan_budget + max(0.0, granted - committed), 6)


def commit_period_consumption(
    conn: sqlite3.Connection, acct: sqlite3.Row, plan_budget: float, closing_spend: float
) -> float:
    """Move a closing period's overage into topup_committed.

    Overage = spend beyond the plan allowance = the part the top-up paid for.
    Without this step the credit would be fully available again after every reset,
    i.e. a one-time top-up would silently become a recurring monthly allowance.
    """
    committed = float(acct["topup_committed"] or 0.0)
    overage = max(0.0, float(closing_spend) - plan_budget)
    committed = round(committed + overage, 6)
    conn.execute(
        "UPDATE accounts SET topup_committed=?, updated_at=? WHERE account_id=?",
        (committed, time.time(), acct["account_id"]),
    )
    if overage > 0:
        LOG.info(
            "account %s closed a period with spend=%.6f -> top-up consumed %.6f "
            "(committed total %.6f)",
            acct["account_id"], closing_spend, overage, committed,
        )
    return committed


def payment_plugin_name(payment_id: str) -> tuple[bool, str]:
    """Which plugin recorded a payment: (ok, pluginName | reason).

    Kill Bill's own `__EXTERNAL_PAYMENT__` plugin is bookkeeping -- it records money
    that arrived OUTSIDE Kill Bill. It can be driven by a human, and it is ALSO what
    the engine reaches for when an account's default payment method is not a real
    gateway. Either way, a payment it records proves nothing about money. Only a
    real gateway plugin (the Stripe plugin) settling a confirmed charge is revenue.

    Two reads: the payment (for its paymentMethodId), then the method (for its
    plugin). Both are cheap GETs and this runs once per paying event.
    """
    if not payment_id:
        return False, "no payment id to resolve"
    status, pay = http_json(
        "GET", f"{KILLBILL_URL}/1.0/kb/payments/{payment_id}", None, killbill_headers()
    )
    if status != 200 or not isinstance(pay, dict):
        return False, f"payment lookup http={status} {str(pay)[:140]}"
    pmid = pay.get("paymentMethodId")
    if not pmid:
        return False, "payment carries no paymentMethodId"
    status, pm = http_json(
        "GET", f"{KILLBILL_URL}/1.0/kb/paymentMethods/{pmid}", None, killbill_headers()
    )
    if status != 200 or not isinstance(pm, dict):
        return False, f"payment method lookup http={status} {str(pm)[:140]}"
    name = str(pm.get("pluginName") or "")
    if not name:
        return False, "payment method carries no pluginName"
    return True, name


def topup_grant_delta(
    conn: sqlite3.Connection,
    invoice_id: str,
    account_id: str,
    paid: float,
    item_total: float,
) -> tuple[float, float, str]:
    """Record a top-up invoice's entitlement; return (delta, entitlement, why).

    The entitlement is what THIS invoice has earned so far: the amount actually
    PAID, capped at what was sold, converted to credit. Only the DELTA since the
    last grant reaches the ledger. That makes the grant idempotent AND correct for
    instalments:

      * a duplicated payment event recomputes the same entitlement -> delta 0;
      * a $5.75 part-payment on an $11.50 invoice earns $5.00, and paying the
        remaining $5.75 later earns the other $5.00 -- never $10 twice.

    Before this, the credit was the ITEM amount granted once per paymentId, so two
    payments against one invoice paid out twice.
    """
    capped = max(0.0, min(float(paid), float(item_total)))
    entitlement = round(capped / TOPUP_FEE_DIVISOR, 6)
    row = conn.execute(
        "SELECT credit FROM topup_grants WHERE invoice_id=?", (invoice_id,)
    ).fetchone()
    already = float(row["credit"]) if row else 0.0
    delta = round(entitlement - already, 6)
    if delta <= 0:
        return 0.0, entitlement, (
            f"invoice {invoice_id} already granted {already:.6f}; nothing further earned"
        )
    conn.execute(
        "INSERT INTO topup_grants(invoice_id,account_id,paid,item_total,credit,updated_at)"
        " VALUES(?,?,?,?,?,?)"
        " ON CONFLICT(invoice_id) DO UPDATE SET paid=excluded.paid,"
        " item_total=excluded.item_total, credit=excluded.credit,"
        " updated_at=excluded.updated_at",
        (invoice_id, account_id, float(paid), float(item_total), entitlement, time.time()),
    )
    return delta, entitlement, (
        f"paid {capped:.6f} of {float(item_total):.6f} -> entitlement {entitlement:.6f} "
        f"(was {already:.6f})"
    )


def reconcile_budgets(conn: sqlite3.Connection) -> int:
    """Keep every ceiling equal to plan + unconsumed top-up credit.

    This exists for the CALENDAR reset. LiteLLM zeroes `spend` on the 1st and
    advances `budget_reset_at`, and no Kill Bill event fires, so without this pass
    the closed period's consumption would never be committed and a one-time top-up
    would quietly become a permanent monthly allowance.

    Fails in the customer's favour: `last_spend` is sampled between sweeps, so a
    burst in the final sampling window under-counts consumption and leaves the
    customer a little extra credit. Never the other way round.
    """
    changed = 0
    rows = conn.execute(
        # Keyed on the KEY HASH, not the budget_id. Provisioning creates keys
        # that carry their own ceiling and are linked to no budget object, so a
        # budget_id-keyed query silently skipped every real customer: their
        # closed period was never committed and a one-time top-up quietly became
        # a permanent monthly allowance (2026-09-29).
        "SELECT * FROM accounts WHERE active=1 "
        "AND litellm_key_hash IS NOT NULL AND litellm_key_hash != ''"
    ).fetchall()
    for acct in rows:
        ok, st = litellm_key_state(acct["litellm_key_hash"])
        if not ok or not isinstance(st, dict):
            LOG.warning("reconcile: %s: %s", acct["account_id"], st)
            continue
        plan_budget = account_plan_budget(conn, acct)
        anchor = (st.get("budget_reset_at") or "").strip()
        rolled = bool(anchor) and anchor != (acct["period_anchor"] or "")
        if rolled:
            commit_period_consumption(conn, acct, plan_budget, float(acct["last_spend"] or 0.0))
            conn.execute(
                "UPDATE accounts SET period_anchor=?, last_spend=0, updated_at=? "
                "WHERE account_id=?",
                (anchor, time.time(), acct["account_id"]),
            )
            acct = conn.execute(
                "SELECT * FROM accounts WHERE account_id=?", (acct["account_id"],)
            ).fetchone()
            LOG.info("reconcile: %s period rolled -> %s", acct["account_id"], anchor)

        desired = topup_ceiling(acct, plan_budget)
        current = st.get("max_budget")
        if current is None or abs(float(current) - desired) > 1e-9:
            ok2, msg = litellm_set_budget(
                acct["budget_id"], desired, acct["litellm_key_hash"] or ""
            )
            if ok2:
                changed += 1
                LOG.info(
                    "reconcile: %s ceiling %s -> %.6f", acct["account_id"], current, desired
                )
            else:
                LOG.warning("reconcile: %s set failed: %s", acct["account_id"], msg)

        conn.execute(
            "UPDATE accounts SET last_spend=?, updated_at=? WHERE account_id=?",
            (float(st.get("spend") or 0.0), time.time(), acct["account_id"]),
        )
    return changed


def payment_id_of(payload: dict) -> str:
    """Return the payment identity Kill Bill publishes in `metaData`.

    `metaData` is itself a JSON *string* nested inside the JSON payload and holds
    the event-specific metadata. For payment events it carries `paymentId`, and
    that is the only field that identifies THE PAYMENT.

    objectId must never be used as the payment identity: for INVOICE_PAYMENT_*
    Kill Bill sets objectType=INVOICE and objectId=<invoiceId> (verified live),
    so every payment against one invoice would collapse to one identity.
    """
    meta = payload.get("metaData")
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except (json.JSONDecodeError, ValueError):
            return ""
    if not isinstance(meta, dict):
        return ""
    for key in ("paymentId", "paymentAttemptId"):
        val = meta.get(key)
        if val:
            return str(val)
    return ""


def transition_identity_of(payload: dict) -> str:
    """Identity of a blocking-state transition. Bug #166.

    A `BLOCKING_STATE` event carries **no `paymentId`**, so for one account the
    tuple (eventType, objectType, objectId, accountId) is IDENTICAL for every
    transition. The cut and the restore therefore hashed to the SAME idem key:
    the restore was ACKed as `duplicate` and silently discarded, and the cut-off
    could never be undone. Proven live 2026-09-30 -- event 383 cut the key, and
    the `__KILLBILL__CLEAR__OVERDUE_STATE__` transition was received with
    `fresh=False` and dropped. This is Bug #149's exact failure mode, one event
    class further out; fixing #149 did not cover it.

    The state NAME alone is not enough: a customer who is cut, pays, and then
    goes overdue again emits `CUST_OD2_BLOCKED` a second time, which would collide
    with the first cut and let them keep service while unpaid. `effectiveDate`
    makes every transition distinct, while a re-delivery of the SAME transition
    still carries the same effectiveDate and still dedupes.
    """
    meta = payload.get("metaData")
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except (json.JSONDecodeError, ValueError):
            return ""
    if not isinstance(meta, dict):
        return ""
    state = str(meta.get("stateName") or "").strip()
    if not state:
        return ""
    return f"{state}@{str(meta.get('effectiveDate') or '').strip()}"


def idem_key_of(payload: dict, raw: bytes, source: str = "webhook") -> str:
    # tenantId is DELIBERATELY excluded. The sweep and the webhook describe the
    # same underlying payment but cannot know the same tenantId (the sweep runs
    # on one tenant's credentials). Including it produced two different keys for
    # one payment, so the sweep would re-apply what the webhook had already done.
    #
    # CORRECTED (Bug #149, 2026-09-18): objectId is NOT sufficient alone, which
    # is what this comment used to claim. For INVOICE_PAYMENT_SUCCESS/FAILED
    # Kill Bill sets objectType=INVOICE and objectId=<invoiceId> (verified live),
    # so every payment against the same invoice produced an IDENTICAL key. The
    # 2nd and later ones hit the UNIQUE constraint, were ACKed as `duplicate`
    # and silently discarded -- the customer paid again and got no budget.
    #
    # The identity of a payment event is the PAYMENT, which Kill Bill publishes
    # in metaData.paymentId (even the official docs point at metaData for the
    # event-specific payload). The sweep recovers the same id from
    # GET /1.0/kb/invoices/{id}/payments, so webhook/sweep dedup still works.
    #
    # This changes the key for events stored before the fix. Re-processing one of
    # those is harmless: the action is "set this budget to this fixed value",
    # which is idempotent by construction.
    parts = [
        str(payload.get("eventType") or ""),
        str(payload.get("objectType") or ""),
        str(payload.get("objectId") or ""),
        str(payload.get("accountId") or ""),
        payment_id_of(payload),
    ]
    # Bug #166: a blocking transition has no paymentId, so without this the cut and
    # the restore hash to the same key and the restore is discarded as a duplicate.
    # DELIBERATELY conditional -- every other event keeps the exact key it had, so
    # no existing dedup row changes meaning. If the transition cannot be identified
    # the raw body is used instead, which still dedupes a re-delivery of the same
    # bytes while never collapsing two DIFFERENT transitions.
    if str(payload.get("eventType") or "").upper() == "BLOCKING_STATE":
        parts.append(transition_identity_of(payload) or hashlib.sha256(raw).hexdigest())
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


def handle_blocking_state(
    acct: sqlite3.Row, row: sqlite3.Row, account_id: str
) -> tuple[str, str]:
    """React to a Kill Bill overdue state change. Returns (new_status, message).

    THE HARD REQUIREMENT (domain-email-and-go-to-market-strategy.md §2.8): "So long
    as we can cut services when payment is missing that's all that matters. From
    both debit/credit AND crypto." The trigger is "is the invoice paid", never "how
    did they pay", so this ONE path covers cards and crypto alike.

    The ladder is the policy (kb-bridge/overdue-custodian.xml, per tenant):

      CUST_OD1_WARNING   day 7+   blockChanges only    -> NOTHING is cut
      CUST_OD2_BLOCKED   day 14+  disableEntitlement   -> CUT
      CUST_OD3_CANCEL    day 30+  disableEntitlement   -> CUT (cancel arrives separately)
      CLEAR              synthesised once nothing matches -> RESTORE

    `CLEAR` is not in the config: Kill Bill synthesises it, which is how "they
    paid" is signalled back. So a restore costs nothing extra here.
    """
    key_hash = (acct["litellm_key_hash"] or "").strip()
    if not key_hash:
        # Cannot act either way. Do not retry forever hoping a hash appears -- but
        # say so loudly, because this account can be neither cut nor restored.
        return "done", (
            f"BLOCKING_STATE for {account_id} but the mapping has no "
            "litellm_key_hash - cannot block or unblock the key"
        )

    try:
        payload = json.loads(row["payload"] or "{}")
    except (TypeError, ValueError):
        return "failed", "BLOCKING_STATE payload is not JSON"

    # metaData arrives as a JSON **STRING**, not an object -- verified against the
    # real live payloads (events 335/336 on VM205). It must be parsed a second time.
    meta = payload.get("metaData")
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except (TypeError, ValueError):
            return "failed", "BLOCKING_STATE metaData is not JSON"
    if not isinstance(meta, dict):
        return "failed", "BLOCKING_STATE carries no usable metaData"

    state = str(meta.get("stateName") or "").strip().upper()
    if not state:
        return "failed", "BLOCKING_STATE carries no stateName"

    if state == OVERDUE_WARN_STATE:
        # §2.8: the bridge sends the warning email itself (one Resend HTTP call).
        # The email is the whole point of OD1 -- but it is still a NOTICE, not
        # enforcement. A missing address is "done" (nothing to send; retrying
        # cannot conjure one), while a send failure is "failed" (retry with
        # backoff so the notice still reaches the reseller). The cut-off
        # (OD2/OD3) is independent and unaffected by either path.
        ok_email, email, why_email, retryable = killbill_account_email(account_id)
        if not ok_email:
            if retryable:
                return "failed", (
                    f"warning (CUST_OD1_WARNING) but {why_email} - will retry"
                )
            return "done", (
                f"warning (CUST_OD1_WARNING) but {why_email} - no dunning email sent"
            )
        body = (
            "<p>Your payment for your Custodian reseller licence is overdue.</p>"
            "<p>If payment is not received, your services will be paused. "
            "Please update your payment method or contact support.</p>"
        )
        idem = f"od1-{account_id}-{meta.get('effectiveDate') or ''}"
        ok, msg = send_dunning_email(email, RESEND_SUBJECT, body, idempotency_key=idem)
        if ok:
            return "done", f"warning (CUST_OD1_WARNING): dunning email sent to {email}"
        return "failed", (
            f"warning (CUST_OD1_WARNING): dunning email to {email} NOT sent ({msg})"
        )

    if state in OVERDUE_BLOCK_STATES:
        # A cut is the most damaging thing this bridge can do, so it gets the same
        # corroboration a payment or a cancellation gets. BLOCKING_STATE arrives on
        # the same unauthenticated callback path as everything else (Bug #153).
        if VERIFY:
            ok, why = killbill_verify_account_overdue(account_id)
            if not ok:
                return "failed", f"refusing to cut: {why}"
        ok, msg = litellm_set_blocked(key_hash, True)
        return (
            ("done" if ok else "failed"),
            f"cut-off: state={state} -> {msg}",
        )

    # Any other state is a transition back to service.
    if VERIFY:
        ok, why = killbill_verify_account_overdue(account_id)
        if ok:
            # They still owe money, so the ladder will re-block on its next pass.
            # Report it as done rather than failed: the state will not re-emit, so
            # retrying could never change the outcome.
            return "done", (
                f"state={state} but the account still has an unpaid invoice "
                f"({why}) - declined to restore; the ladder will re-evaluate"
            )
    ok, msg = litellm_set_blocked(key_hash, False)
    return (("done" if ok else "failed"), f"restore: state={state} -> {msg}")


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

    # Phase 3 -- a failed payment is RECORDED, never acted on. Bug #154's entry is
    # explicit that the dunning POLICY belongs to Kill Bill's overdue ladder
    # (OD1 warn day 7 -> OD2 cut day 14 -> OD3 cancel day 30), so the bridge must
    # not invent a second one. This event is the earliest signal we get, so it is
    # marked done with the ladder's schedule in the reason rather than skipped --
    # "not actionable" would hide it the way it hid three of these already.
    if etype == ACTION_PAYMENT_FAILED:
        return "done", (
            "payment attempt failed (recorded; no action). The overdue ladder owns "
            "the policy: OD1 warning day 7, OD2 cut day 14, OD3 cancel day 30"
        )

    if (
        etype != ACTION_PAYMENT
        and etype not in ACTION_CANCEL
        and etype not in ACTION_BLOCK
    ):
        return "skipped", f"not actionable: {etype or '(no eventType)'}"

    if not account_id:
        return "skipped", "no accountId on event"

    acct = conn.execute(
        "SELECT * FROM accounts WHERE account_id=? AND active=1", (account_id,)
    ).fetchone()
    if acct is None:
        return "skipped", f"no active mapping for account {account_id}"

    budget_id = acct["budget_id"]
    key_hash = (acct["litellm_key_hash"] or "").strip()
    # The ceiling lives ON THE KEY, and provisioning creates keys that carry
    # their own max_budget and are linked to NO budget object. Requiring a
    # budget_id here therefore refused every freshly provisioned customer with
    # "mapping ... has no budget_id", even though the write path no longer needs
    # one. Require a DESTINATION instead: the key hash, or the budget object as
    # the legacy fallback (2026-09-29).
    if not key_hash and not budget_id:
        return "failed", (
            f"mapping for {account_id} has neither a litellm_key_hash nor a "
            "budget_id - nowhere to write the ceiling"
        )

    # Phase 3 -- the cut-off (the hard requirement). It rides the overdue ladder's
    # state change: the ladder owns the policy, this only reacts, so the rule lives
    # in ONE place instead of two.
    if etype in ACTION_BLOCK:
        return handle_blocking_state(acct, row, account_id)

    if VERIFY:
        if etype == ACTION_PAYMENT:
            ok, why = killbill_verify_invoice_paid(account_id, row["object_id"] or "")
        else:
            # Bug #153: a cancellation is a DESTRUCTIVE act -- it drives the budget
            # to on_cancel_budget, which is 0.0 for every seeded plan. It therefore
            # gets the same corroboration the payment path gets. "Are credentials
            # configured?" is not a verification of anything; it let any request
            # bearing the callback path token zero a paying customer's budget.
            if (row["object_type"] or "").upper() != "SUBSCRIPTION":
                ok, why = False, (
                    f"cancellation with objectType={row['object_type']!r} cannot be "
                    f"verified against the engine (expected SUBSCRIPTION) - refusing"
                )
            else:
                ok, why = killbill_verify_subscription_ended(account_id, row["object_id"] or "")
        if not ok:
            return "failed", f"verification refused: {why}"

    if etype == ACTION_PAYMENT:
        plan = acct["plan"]
        prow = conn.execute("SELECT * FROM plans WHERE plan_name=?", (plan,)).fetchone()
        if prow is None:
            return "failed", f"no plan row for plan={plan!r} (account {account_id})"
        plan_budget = account_plan_budget(conn, acct)

        # Which kind of payment is this? A top-up and a subscription payment move
        # the ceiling in different ways, and the push payload does not say which
        # it is -- only the invoice's items do.
        lookup_ok, is_topup, why, money = classify_invoice(account_id, row["object_id"] or "")
        if not lookup_ok:
            return "failed", f"cannot classify the paid invoice: {why}"

        # Whose money is this? A payment can be recorded by hand through Kill
        # Bill's bookkeeping plugin, and the engine itself reaches for that plugin
        # when the account's default payment method is not a real gateway. On a
        # 'card' account only a real gateway settlement is revenue, so refuse the
        # rest loudly instead of granting tokens for a payment nobody made.
        rail = (acct["rail"] or "card").strip().lower()
        try:
            pay_id = payment_id_of(json.loads(row["payload"] or "{}"))
        except (TypeError, ValueError):
            pay_id = ""
        if not pay_id:
            return "failed", "payment event carries no metaData.paymentId - cannot verify the rail"
        pok, pname = payment_plugin_name(pay_id)
        if not pok:
            return "failed", f"cannot resolve the payment's plugin: {pname}"
        if pname == BOOKKEEPING_PLUGIN and rail != "manual":
            # "failed" is retried with backoff (see the worker), which is
            # deliberate: an operator who CORRECTS a mis-set rail should have the
            # real payments heal. Say that in the reason, so nobody flips a rail
            # without knowing it will credit these retroactively.
            return "failed", (
                f"refusing a {pname} payment (rail={rail}, payment {pay_id}): "
                "bookkeeping payments prove no money arrived. Retried with backoff; "
                "set this account to rail=manual ONLY if recorded payments really are "
                "this account's confirmation, because doing so will credit them"
            )

        if is_topup:
            invoice_id = row["object_id"] or ""
            item_total = float(money.get("item_total") or 0.0)
            paid = float(money.get("paid") or 0.0)
            delta, entitlement, why_grant = topup_grant_delta(
                conn, invoice_id, account_id, paid, item_total
            )
            if delta <= 0:
                return "done", f"top-up already credited: {why_grant}"
            granted = round(float(acct["topup_granted"] or 0.0) + delta, 6)
            conn.execute(
                "UPDATE accounts SET topup_granted=?, updated_at=? WHERE account_id=?",
                (granted, time.time(), account_id),
            )
            acct = conn.execute(
                "SELECT * FROM accounts WHERE account_id=?", (account_id,)
            ).fetchone()
            ceiling = topup_ceiling(acct, plan_budget)
            ok, msg = litellm_set_budget(
                budget_id, ceiling, acct["litellm_key_hash"] or ""
            )
            # A top-up raises the ceiling ONLY. It deliberately does NOT clear
            # accrued spend -- that would hand the customer a free period every
            # time they reload, and would let a top-up buy more than it paid for.
            return (("done" if ok else "failed"),
                    f"top-up: {why_grant}; credit +{delta:.6f}; "
                    f"granted total {granted:.6f}; ceiling {ceiling:.6f}; {msg}")

        # A subscription payment zeroes spend, i.e. it ends a period. Commit what
        # the closing period consumed BEFORE erasing it, or the top-up credit would
        # come back in full every month (the recurring-top-up trap).
        closing = float(acct["last_spend"] or 0.0)
        key_hash = (acct["litellm_key_hash"] or "").strip()
        if key_hash:
            okst, st = litellm_key_state(key_hash)
            if okst and isinstance(st, dict):
                closing = float(st.get("spend") or 0.0)
            else:
                LOG.warning(
                    "account %s: could not read spend before reset (%s); "
                    "using last sampled value %.6f", account_id, st, closing,
                )
        commit_period_consumption(conn, acct, plan_budget, closing)
        acct = conn.execute(
            "SELECT * FROM accounts WHERE account_id=?", (account_id,)
        ).fetchone()

        # The ceiling is plan + UNCONSUMED top-up, never the bare plan value:
        # setting it to the plan alone is what silently erased a customer's
        # top-up on the next subscription payment.
        amount = topup_ceiling(acct, plan_budget)
        ok, msg = litellm_set_budget(
            budget_id, amount, acct["litellm_key_hash"] or ""
        )

        # Bug #156 follow-up: raising the ceiling is NOT enough. LiteLLM blocks on
        # `spend >= max_budget`, and /budget/update has no `spend` field, so a
        # customer who burned their allowance, got cut off and then PAID kept the
        # full meter and stayed blocked until the monthly reset. The locked
        # decision is "money in -> tokens available immediately", so clear the
        # accrued spend as well. reset_to=0 is safe (0 <= spend) and idempotent,
        # so a retried event is harmless.
        key_hash = (acct["litellm_key_hash"] or "").strip()
        if not key_hash:
            # Do not fail the event: retrying cannot conjure a hash. Set the
            # ceiling, say loudly what was skipped, and carry on -- but make it
            # visible in the event reason so it is never a silent degradation.
            LOG.warning(
                "account %s has no litellm_key_hash -- ceiling set but accrued spend "
                "NOT reset; run: kb_bridge.py map --account-id %s --budget-id %s "
                "--plan %s --key-hash <key|hash>",
                account_id, account_id, budget_id, plan,
            )
            return ("done" if ok else "failed"), (
                f"{msg}; SPEND NOT RESET (no litellm_key_hash for account {account_id})"
            )

        # Phase 3 -- RESTORE. A payment is the PRIMARY restore signal: it is the one
        # that actually carries money, so it must not depend on the ladder noticing.
        # Verified safe to call on a key that was never blocked -- /key/unblock only
        # 404s when the key does not exist; otherwise it sets blocked=False and
        # invalidates the cache. There is no "already unblocked" error.
        ok3, msg3 = litellm_set_blocked(key_hash, False)
        ok2, msg2 = litellm_reset_spend(key_hash)
        return (
            ("done" if (ok and ok2 and ok3) else "failed"),
            f"{msg}; {msg2}; {msg3}",
        )

    # cancellation
    prow = conn.execute("SELECT * FROM plans WHERE plan_name=?", (acct["plan"],)).fetchone()
    amount = float(prow["on_cancel_budget"]) if prow else 0.0
    ok, msg = litellm_set_budget(budget_id, amount, acct["litellm_key_hash"] or "")
    return ("done" if ok else "failed"), f"cancel -> {msg}"


def backoff_seconds(attempts: int) -> float:
    return min(900.0, 15.0 * (2 ** max(0, attempts - 1)))


# --------------------------------------------------------------------------- #
# receiver
# --------------------------------------------------------------------------- #

_READY = True


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """A ThreadingHTTPServer that refuses a connection BEFORE spawning a thread.

    Bug #152: ThreadingMixIn creates one thread per connection in
    process_request(), so a BoundedSemaphore acquired *inside* the request handler
    bounds concurrent handlers -- not threads, and not accepted connections. A
    connection flood therefore grew threads without limit until the unit hit
    MemoryMax and was killed, which is the worst outcome available here: Kill Bill
    then burns its bounded retries against a dead callback and the payment grant
    is lost. The slot has to be taken here, before the thread exists, or the bound
    does not hold.

    request_queue_size is also raised: the stdlib default is 5, so legitimate
    bursts were being refused at the TCP backlog before our own logic ever ran.
    """

    # Bug #158: this MUST be False. With daemon_threads=True, socketserver's
    # _Threads.append() returns early for daemon threads, so a handler thread is
    # never tracked and server_close()'s join is a no-op -- an in-flight Kill
    # Bill webhook would be abandoned mid-request, and Kill Bill does NOT retry a
    # callback it never got a response from. False makes server_close() join
    # every handler, so a stop drains in-flight events before exiting.
    # Safe against a hung peer: Handler._send() always sends "Connection: close",
    # and the receiver handler is a fast SQLite write (no outbound HTTP).
    daemon_threads = False
    block_on_close = True
    request_queue_size = 128

    def process_request(self, request, client_address):
        if not _SLOTS.acquire(timeout=RECV_SLOT_WAIT_SECONDS):
            LOG.warning("at max concurrency (%s) after %.2fs -- shedding connection",
                        MAX_CONCURRENT, RECV_SLOT_WAIT_SECONDS)
            self._shed(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            _SLOTS.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            _SLOTS.release()

    @staticmethod
    def _shed(request) -> None:
        """Answer 503 straight on the socket: no thread, no handler."""
        try:
            body = b'{"ok": false, "error": "busy"}'
            request.sendall(
                b"HTTP/1.1 503 Service Unavailable\r\n"
                b"Content-Type: application/json\r\n"
                b"Connection: close\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
            )
        except Exception:  # noqa: BLE001 - the peer may already be gone
            pass
        finally:
            try:
                request.close()
            except Exception:  # noqa: BLE001
                pass


class Handler(BaseHTTPRequestHandler):
    server_version = "kb-bridge"
    protocol_version = "HTTP/1.1"
    # Bounds a stalled peer so it cannot wedge the shutdown drain, and so it
    # cannot hold a concurrency slot forever. See RECV_SOCKET_TIMEOUT_SECONDS.
    timeout = RECV_SOCKET_TIMEOUT_SECONDS

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

        # --- bounded concurrency ---
        # The slot is ALREADY held: it is taken in
        # BoundedThreadingHTTPServer.process_request, before this thread was
        # spawned. Acquiring it here would be far too late to bound thread count
        # (Bug #152).
        self._handle_event()

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

    if not PATH_TOKEN:
        LOG.warning("KB_PATH_TOKEN is empty -- receiver will reject everything (fail-closed)")

    # Create the server BEFORE registering signals so _stop can never observe an
    # unbound `httpd`.
    httpd = BoundedThreadingHTTPServer((BIND, PORT), Handler)

    def _stop(signum, _frame):
        global _READY
        LOG.info("signal %s -- shutting down receiver", signum)
        _READY = False
        # Bug #158: serve_forever() runs on THIS thread. Calling
        # httpd.shutdown() directly here would deadlock -- the CPython docs are
        # explicit:
        #   "shutdown() must be called while serve_forever() is running in a
        #    different thread otherwise it will deadlock."
        # (_BaseServer__is_shut_down is only set by serve_forever's finally
        # block, which cannot run while this handler occupies this thread.)
        # Before this fix nothing called shutdown() at all, so serve_forever()
        # never returned, server_close() never ran, and the process always burned
        # the full TimeoutStopSec and died by SIGKILL.
        # Hand the call to a helper thread; it returns as soon as serve_forever()
        # exits, bounded by poll_interval.
        threading.Thread(
            target=httpd.shutdown, daemon=True, name="httpd-shutdown"
        ).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    LOG.info(
        "receiver listening on %s:%s  path=/kb/events/<token>  db=%s  "
        "max_concurrent=%s  backlog=%s",
        BIND, PORT, DB_PATH, MAX_CONCURRENT, httpd.request_queue_size,
    )
    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        # Bug #158 follow-up: bound the drain. server_close() joins every
        # in-flight handler with no timeout of its own, so one peer that stalls
        # (or dribbles bytes forever) would hold the join open, we would hit
        # TimeoutStopSec, and systemd would SIGKILL us -- the very symptom this
        # change exists to remove. Arm an absolute deadline before joining.
        threading.Thread(
            target=_force_exit_after, args=(DRAIN_BUDGET_SECONDS,),
            daemon=True, name="drain-deadline",
        ).start()
        httpd.server_close()
    return 0


def _force_exit_after(seconds: float) -> None:
    """Absolute ceiling on the shutdown drain. See run_receiver."""
    time.sleep(seconds)
    LOG.warning(
        "drain budget of %ss exceeded -- abandoning in-flight handlers", seconds
    )
    logging.shutdown()
    os._exit(0)


# --------------------------------------------------------------------------- #
# worker
# --------------------------------------------------------------------------- #

_WORK = True


def claim_batch(conn: sqlite3.Connection, limit: int) -> tuple[str, list[sqlite3.Row]]:
    """Claim up to `limit` rows under a fresh lease. Returns (lease_token, rows).

    The token is the credential for this claim. Every later write made on behalf
    of these rows must present it, so a worker that was declared dead, then came
    back, cannot clobber a row another worker has legitimately reclaimed in the
    meantime (the "one job, two writers" failure).
    """
    now = time.time()
    token = uuid.uuid4().hex
    conn.execute("BEGIN IMMEDIATE")
    try:
        rows = conn.execute(
            "SELECT * FROM events WHERE status='pending' AND next_attempt_at<=? "
            "ORDER BY id LIMIT ?",
            (now, limit),
        ).fetchall()
        if rows:
            conn.executemany(
                "UPDATE events SET status='processing', attempts=attempts+1, "
                "lease_token=?, lease_expires_at=?, owner=? WHERE id=?",
                [(token, now + LEASE_SECONDS, WORKER_OWNER, r["id"]) for r in rows],
            )
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return token, rows


def renew_lease(conn: sqlite3.Connection, token: str) -> None:
    """Heartbeat: "I am alive and I still hold these rows."

    Called as the worker finishes each row of a batch, so a batch that runs longer
    than LEASE_SECONDS does not have its tail reclaimed out from under a worker
    that is working perfectly well.
    """
    conn.execute(
        "UPDATE events SET lease_expires_at=? WHERE lease_token=? AND status='processing'",
        (time.time() + LEASE_SECONDS, token),
    )


def reclaim_expired(conn: sqlite3.Connection) -> int:
    """Return abandoned rows to the queue. The half of Bug #150 that was missing.

    A row stuck in 'processing' is worse than a failed one: it is INVISIBLE. It
    is not 'pending' (so no worker ever picks it up), not 'failed' (so nothing
    alarms), and the queue looks healthy. Only lease expiry reveals it.
    """
    now = time.time()
    rows = conn.execute(
        "SELECT id, attempts FROM events WHERE status='processing' "
        "AND lease_expires_at IS NOT NULL AND lease_expires_at < ? "
        "ORDER BY id LIMIT ?",
        (now, REAP_BATCH),
    ).fetchall()
    if not rows:
        return 0
    for r in rows:
        if r["attempts"] >= MAX_ATTEMPTS:
            # A row that keeps killing its worker must reach a terminal state
            # rather than crash-looping forever.
            conn.execute(
                "UPDATE events SET status='failed', last_error=?, processed_at=?, "
                "lease_token=NULL, lease_expires_at=NULL WHERE id=?",
                (f"lease expired after {r['attempts']} attempts "
                 f"(worker died or hung every time)", now, r["id"]),
            )
        else:
            conn.execute(
                "UPDATE events SET status='pending', next_attempt_at=?, last_error=?, "
                "lease_token=NULL, lease_expires_at=NULL WHERE id=?",
                (now, "lease expired - reclaimed (worker died or hung)", r["id"]),
            )
    LOG.warning("reclaimed %s abandoned event(s) whose lease had expired", len(rows))
    return len(rows)


def release_own_leases(conn: sqlite3.Connection) -> int:
    """On graceful shutdown, hand back anything this process still holds.

    Without this a clean restart has to wait out the whole lease before those
    rows are picked up again.
    """
    cur = conn.execute(
        "UPDATE events SET status='pending', next_attempt_at=0, "
        "lease_token=NULL, lease_expires_at=NULL "
        "WHERE status='processing' AND owner=?",
        (WORKER_OWNER,),
    )
    return cur.rowcount or 0


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
        "worker started  db=%s  litellm=%s  verify=%s  lease=%ss  owner=%s  "
        "plan_default_duration=%s",
        DB_PATH, LITELLM_URL, VERIFY, LEASE_SECONDS, WORKER_OWNER,
        BUDGET_DURATION or "(none)",
    )

    conn = db()
    idle_logged = False
    try:
        while _WORK:
            # Bug #150: before looking for work, take back any row whose owner
            # died. This is the only thing standing between a mid-batch SIGKILL
            # and a permanently stranded payment.
            reclaim_expired(conn)

            token, rows = claim_batch(conn, BATCH)
            if not rows:
                if not idle_logged:
                    LOG.debug("queue empty")
                    idle_logged = True
                time.sleep(POLL_SECONDS)
                continue
            idle_logged = False

            for idx, row in enumerate(rows):
                try:
                    status, msg = process_event(conn, row)
                except Exception as exc:  # noqa: BLE001
                    status, msg = "failed", f"{type(exc).__name__}: {exc}"

                now = time.time()
                # Every terminal write carries `AND lease_token=?`. If our lease
                # was reclaimed while we worked, rowcount is 0: another worker now
                # owns this row and has already decided its outcome. Do not fight
                # it -- that is the "one job, two writers" corruption the token
                # exists to prevent.
                if status == "failed":
                    attempts = row["attempts"] + 1
                    if attempts >= MAX_ATTEMPTS:
                        LOG.error("event id=%s gave up after %s attempts: %s",
                                  row["id"], attempts, msg)
                        n = conn.execute(
                            "UPDATE events SET status='failed', last_error=?, processed_at=?, "
                            "lease_token=NULL, lease_expires_at=NULL "
                            "WHERE id=? AND lease_token=?",
                            (msg[:500], now, row["id"], token),
                        ).rowcount
                    else:
                        delay = backoff_seconds(attempts)
                        LOG.warning("event id=%s attempt %s failed (%s); retry in %.0fs",
                                    row["id"], attempts, msg[:160], delay)
                        n = conn.execute(
                            "UPDATE events SET status='pending', last_error=?, next_attempt_at=?, "
                            "lease_token=NULL, lease_expires_at=NULL "
                            "WHERE id=? AND lease_token=?",
                            (msg[:500], now + delay, row["id"], token),
                        ).rowcount
                else:
                    LOG.info("event id=%s %s: %s", row["id"], status, msg[:200])
                    n = conn.execute(
                        "UPDATE events SET status=?, last_error=?, processed_at=?, "
                        "lease_token=NULL, lease_expires_at=NULL "
                        "WHERE id=? AND lease_token=?",
                        (status, msg[:500], now, row["id"], token),
                    ).rowcount

                if not n:
                    LOG.warning("event id=%s result discarded: our lease had been "
                                "reclaimed, another worker owns it now", row["id"])

                if idx < len(rows) - 1:
                    renew_lease(conn, token)  # heartbeat for the rest of the batch
    finally:
        # Hand back anything still held, so a clean restart does not have to wait
        # out the full lease before those rows are picked up again.
        try:
            released = release_own_leases(conn)
            if released:
                LOG.info("released %s unprocessed event(s) back to the queue", released)
        except Exception:  # noqa: BLE001 - shutdown path, never raise
            pass
        conn.close()
    return 0


# --------------------------------------------------------------------------- #
# sweep (reconciliation -- covers events that exhausted Kill Bill's retries)
# --------------------------------------------------------------------------- #


def _sweep_payment_id(invoice_id: str) -> tuple[str, str]:
    """Return (paymentId, note) for the payment that completed an invoice.

    The sweep has to produce the SAME idempotency identity the webhook would
    have, or the two sources stop de-duplicating against each other. Kill Bill's
    Invoice definition carries no `payments` array (verified live), so the id
    comes from the dedicated payments endpoint.
    """
    st, pays = http_json(
        "GET", f"{KILLBILL_URL}/1.0/kb/invoices/{invoice_id}/payments",
        None, killbill_headers(),
    )
    if st != 200 or not isinstance(pays, list):
        return "", f"payments lookup http={st} {str(pays)[:120]}"

    best, best_num = "", -1
    for p in pays:
        if not isinstance(p, dict):
            continue
        # Only a genuinely successful PURCHASE moved money. A credit or a voided
        # attempt must not be mistaken for the payment.
        if not any(
            str(t.get("transactionType") or "").upper() == "PURCHASE"
            and str(t.get("status") or "").upper() == "SUCCESS"
            for t in (p.get("transactions") or [])
        ):
            continue
        try:
            num = int(str(p.get("paymentNumber") or "0"))
        except (TypeError, ValueError):
            num = 0
        if num >= best_num:
            best_num, best = num, str(p.get("paymentId") or "")
    return best, "ok"


def _sweep_consider_invoice(conn: sqlite3.Connection, inv: dict) -> tuple[bool, str]:
    """Decide whether one invoice needs a payment event, and enqueue it.

    `inv` must carry an AUTHORITATIVE `balance`. There are exactly two read paths
    that provide one, and both are proven live against 0.24.21:

      * `GET /1.0/kb/invoices/byNumber/{n}` or `/invoices/{id}` -- the DETAIL
        endpoints load invoice items, so DefaultInvoice's items-based balance is
        real; and
      * `GET /1.0/kb/invoices/search/_q=1&balance[...]` -- the BALANCE SEARCH,
        whose balance is computed in SQL (`invoiceBalanceQuery`) and is therefore
        real even though it returns no items at all.

    What must NEVER be used is the plain LIST endpoint
    (`/invoices/pagination`, `/accounts/{id}/invoices` without
    `includeInvoiceComponents=true`). The official docs say it plainly: it
    returns SHALLOW invoices with `amount`, `creditAdj`, `refundAdj` and
    `balance` forced to 0. Verified live 2026-09-28 -- it reported balance 0.0
    for an invoice genuinely owing $59. Trusting it manufactured a false
    INVOICE_PAYMENT_SUCCESS for an unpaid $59 invoice (observed 2026-09-18).

    Both advanced search forms look alike but only one is safe: the FIELD form
    (`_q=1&status=...`) returns `balance: null`. A missing balance is therefore
    treated as a hard refusal below, never as "probably paid".
    """
    inv_id = inv.get("invoiceId")
    if not inv_id:
        return False, "no invoiceId"

    status = str(inv.get("status") or "").upper()
    if status != "COMMITTED":
        return False, f"status={status or 'missing'}"

    balance = inv.get("balance")
    if balance is None:
        # A missing balance means we read from a path that cannot answer the
        # question (the field-search form). Refuse loudly: "no balance" must
        # never be read as "no money owed".
        return False, (
            "REFUSING: invoice returned no balance field -- wrong read path "
            "(the field-search form reports balance as null)"
        )
    if float(balance) > 0:
        return False, f"not fully paid (balance={balance})"

    account_id = inv.get("accountId")
    if not account_id:
        return False, "no accountId"

    pid, note = _sweep_payment_id(inv_id)
    if not pid:
        # Fully paid with no successful payment on record means something other
        # than money settled it (a credit / CBA). No payment, no budget: fail
        # closed rather than grant service nobody paid for.
        return False, f"fully paid but no successful payment on record ({note}) - not granting"

    synthetic = {
        "eventType": ACTION_PAYMENT,
        "objectType": "INVOICE",
        "objectId": inv_id,
        "accountId": account_id,
        # metaData is a JSON *string* in real payloads; mirror that so the
        # idempotency key comes out identical to the webhook's.
        "metaData": json.dumps({"paymentId": pid}),
    }
    raw = json.dumps(synthetic, sort_keys=True).encode()
    if enqueue(conn, synthetic, raw, source="sweep"):
        return True, f"enqueued invoice={inv_id} payment={pid}"
    return False, "already queued (duplicate)"


def _sweep_already_recorded(conn: sqlite3.Connection, invoice_id: str) -> bool:
    """Have we already enqueued a payment event for this invoice?

    An OPTIMISATION, so that the cost of a run does not grow with every invoice
    the tenant has ever had. Without it the sweep would re-read the whole paid
    set each run AND spend one `/invoices/{id}/payments` call per invoice, so a
    tenant with a few thousand paid invoices would fire a few thousand requests
    every 15 minutes -- trading a log-bloat problem for a request storm.

    Why skipping is safe here, stated plainly: if an event row already exists for
    this invoice, a payment notification for that customer DID arrive. The
    sweep's whole purpose is the opposite case -- the notification path is broken
    for someone, so NO event exists. A customer with a broken path is therefore
    still examined on every run.

    The residual gap: a SECOND missed payment against an already-processed
    invoice is not independently caught by the sweep. That case is the webhook's
    (and Bug #149's per-`paymentId` identity fix is what makes two payments on
    one invoice two distinct events). It is not silently ignored -- every run
    reports `skipped_known=` in its summary line.

    This can only ever skip work: anything already recorded is still
    de-duplicated by `enqueue`'s UNIQUE constraint, so it can never double-apply.
    """
    return conn.execute(
        "SELECT 1 FROM events WHERE object_id=? AND event_type=? LIMIT 1",
        (invoice_id, ACTION_PAYMENT),
    ).fetchone() is not None


def run_sweep(once: bool = False) -> int:
    """Find invoices that are fully paid but whose payment event never arrived.

    This is the backstop for a missed webhook: if an `INVOICE_PAYMENT_SUCCESS` is
    dropped, a paying customer stays cut off. The sweep re-derives the payment
    from the engine and enqueues the identical event, so the webhook and the
    sweep de-duplicate against each other.

    Read path (Bug #157)
    --------------------
        GET /1.0/kb/invoices/search/_q=1&balance[lte]=0?offset=&limit=
    the documented balance search -- instead of walking invoice NUMBERS from a
    stored watermark.

    Why the number walk is gone
    ---------------------------
    `invoiceNumber` IS `invoices.record_id` (`InvoiceSqlDao.sql.stg`:
    `record_id as invoice_number`) -- a per-table auto-increment shared by EVERY
    tenant in the database. It is dense only in a single-tenant install. The old
    walk probed `watermark+1` upward and would only accept that history had ended
    after `KB_SWEEP_MAX_GAPS` (50) consecutive misses, so on a shared database a
    51-record gap ended the walk early and blinded reconciliation -- permanently,
    and silently. And because a tenant holding two invoices still had to walk 50
    dead numbers to discover that, it re-probed the same dead range on every run:
    50 engine stack traces and ~700 KB of log per run (measured 2026-09-28),
    ~67 MB/day, forever.

    The balance search does not care about numbers at all. It asks the engine the
    question we actually have -- "which invoices are fully paid?" -- and its
    `balance` is computed in SQL (`invoiceBalanceQuery`: SUM(items) - SUM(successful
    payments + refunds), zeroed for DRAFT/VOID/migrated/written-off), so it is
    authoritative WITHOUT loading invoice items. That matters: the plain list
    endpoints return shallow invoices and report balance 0.0 for an invoice that
    genuinely owes money (verified live: a $59 invoice reported as 0.0) -- the
    2026-09-18 false positive. Rationale in full on `_sweep_consider_invoice`.

    Why not a "changed since" cursor
    --------------------------------
    Both alternatives were ruled out on evidence, not taste:
      * `/accounts/{id}/invoices?startDate=...` filters `target_date`, a
        service-period BUSINESS date that can be backdated -- so a late correction
        written against an old period would never be seen again;
      * the field-search form (`_q=1&created_date[gte]=...`) returns
        `balance: null`, so it cannot decide paid/unpaid at all. `InvoiceJson`
        exposes no `createdDate` either: an invoice's creation instant is simply
        not observable through this API.

    Self-healing by construction
    ----------------------------
    Every run re-reads the whole set from offset 0, so there is no watermark to
    advance, none to corrupt, and a run interrupted half way loses nothing -- the
    next run reads it all again. Termination uses the documented pagination
    contract: keep paging while `X-Killbill-Pagination-NextOffset` is present.
    """
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
            # Phase 2: keep every ceiling equal to plan + unconsumed top-up credit.
            # Its own guard so a ledger problem can never stop the invoice
            # reconciliation below, which is the safety net for missed webhooks.
            try:
                n_reconciled = reconcile_budgets(conn)
                if n_reconciled:
                    LOG.info("sweep: reconciled %d budget ceiling(s)", n_reconciled)
            except Exception as exc:  # noqa: BLE001 - never let this kill the sweep
                LOG.exception("sweep: budget reconcile failed: %s", exc)

            examined = 0
            added = 0
            skipped_known = 0
            pages = 0
            offset = 0
            highest = 0
            total = None
            capped = False
            failed = ""

            while pages < SWEEP_MAX_PAGES:
                url = (f"{KILLBILL_URL}/1.0/kb/invoices/search/{SWEEP_BALANCE_QUERY}"
                       f"?offset={offset}&limit={SWEEP_PAGE_SIZE}")
                st, page, hdrs = http_json_hdrs("GET", url, None, killbill_headers())
                if st != 200 or not isinstance(page, list):
                    failed = f"http={st} {str(page)[:180]}"
                    LOG.error(
                        "sweep: balance search failed at offset=%s %s -- stopping",
                        offset, failed,
                    )
                    break
                pages += 1

                if total is None:
                    raw_total = hdrs.get("X-Killbill-Pagination-TotalNbRecords")
                    try:
                        total = int(raw_total) if raw_total is not None else None
                    except (TypeError, ValueError):
                        total = None

                for inv in page:
                    if not isinstance(inv, dict):
                        continue
                    examined += 1
                    try:
                        highest = max(highest, int(inv.get("invoiceNumber") or 0))
                    except (TypeError, ValueError):
                        pass

                    inv_id = str(inv.get("invoiceId") or "")
                    if inv_id and _sweep_already_recorded(conn, inv_id):
                        skipped_known += 1
                        continue

                    ok, why = _sweep_consider_invoice(conn, inv)
                    if ok:
                        added += 1
                        LOG.warning("sweep: %s", why)

                nxt = hdrs.get("X-Killbill-Pagination-NextOffset")
                if nxt is None:
                    # Documented contract: the header is present ONLY when there
                    # are further entries, so its absence is the end of the set.
                    break
                try:
                    offset = int(nxt)
                except (TypeError, ValueError):
                    failed = f"unparseable NextOffset {nxt!r}"
                    LOG.error("sweep: %s -- stopping", failed)
                    break
            else:
                # Exited on the page counter rather than on NextOffset: we ran
                # out of budget before the engine ran out of invoices.
                capped = True

            if highest:
                # OBSERVABILITY ONLY. This is NOT a cursor -- nothing reads it
                # back to decide where to resume (every run re-reads the set).
                # Kept so operators can see the high-water mark at a glance, and
                # so a rollback to the number walk has a sane starting point.
                conn.execute(
                    "INSERT INTO meta(k,v) VALUES('sweep_last_invoice_number',?) "
                    "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                    (str(highest),),
                )

            if capped:
                LOG.warning(
                    "sweep INCOMPLETE: hit its page cap (%s pages x %s invoices = %s). "
                    "examined=%s enqueued=%s skipped_known=%s set_size=%s. Coverage was "
                    "NOT complete -- raise KB_SWEEP_MAX_PAGES.",
                    SWEEP_MAX_PAGES, SWEEP_PAGE_SIZE,
                    SWEEP_MAX_PAGES * SWEEP_PAGE_SIZE,
                    examined, added, skipped_known,
                    total if total is not None else "unknown",
                )
            elif failed:
                LOG.warning(
                    "sweep stopped early after %s page(s): %s. examined=%s enqueued=%s "
                    "skipped_known=%s -- nothing was recorded as complete, so the next "
                    "run re-reads the whole set",
                    pages, failed, examined, added, skipped_known,
                )
            else:
                LOG.info(
                    "sweep complete: pages=%s examined=%s enqueued=%s skipped_known=%s "
                    "set_size=%s highest_invoice_number=%s",
                    pages, examined, added, skipped_known,
                    total if total is not None else "unknown", highest,
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
        print(f"worker lease  : {LEASE_SECONDS}s  owner={WORKER_OWNER}  reap_batch={REAP_BATCH}")
        print(f"sweep scope   : balance search (balance<=0), max {SWEEP_MAX_PAGES} pages "
              f"x {SWEEP_PAGE_SIZE} invoices/run")
        print()
        print("events by status:")
        for r in conn.execute(
            "SELECT status, COUNT(*) c FROM events GROUP BY status ORDER BY status"
        ):
            print(f"   {r['status']:12} {r['c']}")
        # A row whose lease expired is invisible everywhere else: not pending (no
        # worker takes it) and not failed (nothing alarms). Surface it here.
        now = time.time()
        stuck = conn.execute(
            "SELECT COUNT(*) c FROM events WHERE status='processing' "
            "AND lease_expires_at IS NOT NULL AND lease_expires_at < ?",
            (now,),
        ).fetchone()["c"]
        held = conn.execute(
            "SELECT COUNT(*) c FROM events WHERE status='processing'"
        ).fetchone()["c"]
        print(f"   lease held   {held}   abandoned (expired, awaiting reclaim) {stuck}")
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


def normalise_key_hash(value: str) -> str:
    """Accept either a plaintext LiteLLM key or its sha256 hash; never store plaintext.

    LiteLLM's `hash_token` is plain sha256 hex (verified live: our locally
    computed sha256 matched the `key_hash` the proxy returned). Returns "" for
    anything that is neither, so a typo can never be written to the DB.
    """
    v = (value or "").strip()
    if not v:
        return ""
    if len(v) == 64 and all(c in "0123456789abcdef" for c in v.lower()):
        return v.lower()
    if v.startswith("sk-"):
        return hashlib.sha256(v.encode()).hexdigest()
    return ""


def run_map(args) -> int:
    init_db()
    key_hash = normalise_key_hash(args.key_hash)
    if args.key_hash and not key_hash:
        print(f"refusing --key-hash {args.key_hash[:6]}...: expected an sk-... key "
              f"or a 64-char sha256 hex", file=sys.stderr)
        return 2
    conn = db()
    try:
        conn.execute(
            "INSERT INTO accounts(account_id,budget_id,key_alias,litellm_key_hash,"
            " plan,active,note,rail,updated_at)"
            " VALUES(?,?,?,?,?,?,?,?,?)"
            " ON CONFLICT(account_id) DO UPDATE SET budget_id=excluded.budget_id,"
            " key_alias=excluded.key_alias,"
            # never blank an existing hash just because this call omitted it
            " litellm_key_hash=COALESCE(NULLIF(excluded.litellm_key_hash,''),"
            "                          accounts.litellm_key_hash),"
            " plan=excluded.plan, active=excluded.active,"
            " note=excluded.note, rail=excluded.rail, updated_at=excluded.updated_at",
            (args.account_id, (args.budget_id or None), args.key_alias, key_hash, args.plan,
             0 if args.disable else 1, args.note, args.rail, time.time()),
        )
        print(f"mapped account {args.account_id} -> budget {args.budget_id or '(none - key carries the ceiling)'} "
              f"plan={args.plan} active={not args.disable} rail={args.rail} "
              f"key_hash={'set' if key_hash else 'not set'}")
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


def run_topup(args) -> int:
    """Sell a top-up by creating the Kill Bill external charge that represents it.

    A catalog plan cannot express an arbitrary amount ("one-time, min $10, no
    max"), so a top-up is an EXTERNAL CHARGE carrying TOPUP_MARKER in itemDetails.
    The customer pays the resulting invoice through the normal payment path, and
    the bridge credits the budget when INVOICE_PAYMENT_SUCCESS arrives -- at
    `paid / TOPUP_FEE_DIVISOR`, i.e. the fee is ON TOP (pricing model §2).

    The line item is a single blended figure on purpose. Never print or invoice
    "tokens $X + fee $Y" -- the One Rule: one number, no itemised breakdown.
    """
    init_db()
    if not killbill_configured():
        print("Kill Bill is not configured (KB_KILLBILL_URL + api key/secret + user/password)")
        return 1

    tokens = float(args.budget_amount)
    if tokens < MIN_TOPUP_TOKENS:
        print(f"refusing: the minimum top-up is ${MIN_TOPUP_TOKENS:.2f} of tokens")
        return 2
    charge = round(tokens * TOPUP_FEE_DIVISOR, 2)

    body = [{
        "amount": charge,
        "currency": args.currency,
        "description": "Token top-up",
        "itemDetails": TOPUP_MARKER,
    }]
    url = f"{KILLBILL_URL}/1.0/kb/invoices/charges/{args.account_id}?autoCommit=true"
    status, resp = http_json("POST", url, body, killbill_headers())
    if status not in (200, 201) or not isinstance(resp, list) or not resp:
        print(f"external charge failed: http={status} {str(resp)[:300]}")
        return 1

    invoice_id = resp[0].get("invoiceId")
    print(f"top-up: ${tokens:.2f} of tokens -> a single charge of ${charge:.2f}")
    print(f"invoice: {invoice_id}")
    print("the customer pays that invoice; the budget is credited on INVOICE_PAYMENT_SUCCESS")
    return 0


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
    m.add_argument("--budget-id", default="",
                   help="OPTIONAL. LiteLLM budget object id. Provisioning creates keys "
                        "that carry their own max_budget and are linked to NO budget "
                        "object, so a real customer normally has none. The ceiling is "
                        "written on the key; this is only the legacy fallback for an "
                        "account with no key hash.")
    m.add_argument("--plan", default="basic")
    m.add_argument("--rail", default="card", choices=("card", "manual"),
                   help="which rail collects this account's money. 'card' (default) "
                        "= Kill Bill auto-charges the saved Stripe method, so a "
                        "bookkeeping payment is refused; 'manual' = crypto/offline, "
                        "where a hand-recorded payment IS the confirmation")
    m.add_argument("--key-alias", default="")
    m.add_argument("--key-hash", default="",
                   help="customer LiteLLM key (sk-...) or its sha256 hash. Required for "
                        "spend to be reset when they pay; the plaintext key is hashed "
                        "and never stored.")
    m.add_argument("--note", default="")
    m.add_argument("--disable", action="store_true")

    pl = sub.add_parser("plan")
    pl.add_argument("--plan-name", required=True)
    pl.add_argument("--max-budget", type=float, required=True)
    pl.add_argument("--on-cancel", type=float, default=0.0)

    tp = sub.add_parser("topup", help="create a top-up charge on a customer account")
    tp.add_argument("--account-id", required=True)
    tp.add_argument("--budget-amount", type=float, required=True,
                    help="TOKENS to credit, e.g. 10 for $10 of tokens "
                         f"(minimum ${MIN_TOPUP_TOKENS:.2f}); the charge is 1.15x this")
    tp.add_argument("--currency", default="USD")

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
    if args.cmd == "topup":
        return run_topup(args)
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
