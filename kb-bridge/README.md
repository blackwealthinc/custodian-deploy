# kb-bridge — Kill Bill → LiteLLM budget bridge

Turns Kill Bill billing events into LiteLLM budget changes.

```
Kill Bill (billing engine, .104)
      │  POST  http://192.168.50.205:8555/kb/events/<token>
      ▼
┌──────────────────────────────────────────────────────────┐
│ VM205 (co-located with LiteLLM)                          │
│                                                          │
│  kb-bridge-receiver   accept → persist → 200             │
│           │                                              │
│           ▼   SQLite queue (WAL)                         │
│  kb-bridge-worker     verify → plan → POST /budget/update│
│           │                                              │
│  kb-bridge-sweep.timer  every 15 min: catch missed events│
└───────────┬──────────────────────────────────────────────┘
            ▼
    LiteLLM 127.0.0.1:4000  →  enforces the budget per customer
```

No third-party Python packages. Stdlib only — VM205 has ~750 MiB free.

## Why it is shaped like this

Four facts from the Kill Bill source (tag `killbill-0.24.21`, the version on `.104`) drove the design. All were verified by reading the code, not assumed.

**1. Kill Bill makes the HTTP call itself, synchronously, on its event-bus thread, with a 15-second timeout.**
`PushNotificationListener.triggerPushNotifications` is `@Subscribe` + `@AllowConcurrentEvents` and calls `doPost(..., TIMEOUT_NOTIFICATION, 0)` directly; `TIMEOUT_NOTIFICATION = 15`. The official docs' own sample log shows the thread name `th='bus_events-th'`.

**2. And there may be only ONE bus thread.** Kill Bill's shipped config sets:
```
org.killbill.persistent.bus.main.nbThreads=1
org.killbill.persistent.bus.main.queue.capacity=1000
```
Our deploy does not override it. So a stalled callback cannot just slow one worker — it can **stop all event dispatch**. This is why the receiver's latency ceiling is treated as a hard safety property, not a performance nicety.

> The receiver therefore does nothing but persist and ACK. The fast path, and the two guards that keep it fast, are described under *Receiver hardening* below.

**3. There is exactly ONE callback URL per tenant, and Kill Bill sends no auth header.**
Callbacks are a *single-value* tenant KV — `TenantKV.TenantKey` declares `PUSH_NOTIFICATION_CB(true)`, and `addTenantKeyValue(..., uniqueKey, ...)` soft-deletes every existing row for the key before inserting (`markTenantKeyAsDeleted` → `is_active = FALSE`), while the read (`getTenantValueForKey`) filters `is_active = TRUE`. So a second `POST` **replaces** the first, at four independent layers.

`doPost` sets only `User-Agent: KillBill/1.0` and `Content-Type`. **There is no way to send a shared secret.**

> So the secret lives in the **URL path** — a noise filter, not real auth. The real control is the network layer. And because one URL serves all of a tenant's events, routing must fan out *inside* the receiver.

**4. Delivery is at-least-once, retries are bounded, and events can be lost.**
A non-2xx is retried from a DB-backed queue on a per-tenant schedule (default `15m,30m,2h,12h,1d`), then stops ("Max attempt number reached") — confirmed by the maintainers' own `TestPushNotification` tests (initial attempt + 5 retries = 6 calls, then it stays at 6).

> So the consumer is **idempotent** (`UNIQUE(idem_key)` collapses retries) and there is a **sweep** for what retries gave up on.

### Security posture

Kill Bill PR **#2183** (SSRF via callback URL) is **open and unmerged**, and webhooks are unsigned on our side. So: bind to the LAN, firewall to the Kill Bill host, keep the secret in the path — and **never trust an inbound event**. With `KB_VERIFY=1` the worker re-reads the invoice from Kill Bill before granting anything, and **fails closed** when Kill Bill is unreachable. A forged or replayed event therefore grants nothing.

## Receiver hardening

Two guards exist purely to bound latency, because of finding (2):

| Guard | Default | Why |
|---|---|---|
| `KB_RECV_BUSY_TIMEOUT_MS` | `250` | If the worker holds the SQLite write lock, fail fast with a 500 (Kill Bill retries) instead of parking for seconds. At the 5000 ms default this measured **5.02 s**. |
| `KB_MAX_CONCURRENT` + `KB_RECV_SLOT_WAIT_SECONDS` | `32` / `0.15` | `ThreadingHTTPServer` spawns an uncapped thread per connection. Wait briefly for a slot, then shed with `503`. Worst case ≈ wait + busy timeout ≈ 0.4 s. |

## Install

Idempotent — safe to re-run. Reuses the existing token and database.

```bash
curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/kb-bridge/install-kb-bridge.sh | sudo -E bash
```

It prints the exact callback URL to register; the bare token is also at `/opt/kb-bridge/.token` (mode 600).

> Currently run from a checked-out copy, because the script reads the LiteLLM master key out of the container (`/tmp/.kbmk`) rather than taking it on the command line — that keeps the secret out of shell history and out of any transcript.

## Usage

```bash
sudo python3 /opt/kb-bridge/kb_bridge.py status    # queue depth, config sanity, errors
sudo python3 /opt/kb-bridge/kb_bridge.py plan  --plan-name basic --max-budget 5.0
sudo python3 /opt/kb-bridge/kb_bridge.py map   --account-id <killbill-account-uuid> \
        --budget-id <litellm-budget-id> --plan basic
sudo journalctl -u kb-bridge-worker -f
```

Register the callback once per tenant (needs that tenant's API credentials):

```bash
curl -X POST "http://192.168.50.104:8080/1.0/kb/tenants/registerNotificationCallback?cb=http://192.168.50.205:8555/kb/events/<token>" \
  -u admin:password \
  -H "X-Killbill-ApiKey: <key>" -H "X-Killbill-ApiSecret: <secret>" \
  -H "X-Killbill-CreatedBy: custodian" -H "Content-Type: application/json"
```

`GET` the same URL to read it back; `DELETE` clears it.

## How an event is handled

| Event | Action |
|---|---|
| `INVOICE_PAYMENT_SUCCESS` | verify the invoice, then set the budget to `plans.max_budget` |
| `SUBSCRIPTION_CANCEL`, `SUBSCRIPTION_EXPIRED` | set the budget to `plans.on_cancel_budget` (default `0.0`) |
| `SUBSCRIPTION_CHANGE` | **skipped with an explicit reason** — see *Known gaps* |
| anything else | acknowledged, marked `skipped` — not an error |
| unknown account | `skipped` with `no active mapping` — not an error |

Retries use exponential backoff (15 s → 15 min) up to `KB_MAX_ATTEMPTS`, then park as `failed` with the reason in `last_error`.

## The sweep (reconciliation)

Reads **invoices**, not payments:

```
GET /1.0/kb/invoices/pagination?offset=N&limit=100&audit=true
  → keep invoices with status == COMMITTED and balance == 0
  → enqueue as INVOICE_PAYMENT_SUCCESS
```

A `sweep_last_invoice_number` watermark avoids re-processing. **The watermark is only advanced when the walk completes** — on a truncated walk (page cap reached) it is deliberately left alone, because advancing on a partial scan would skip every invoice past the cap permanently. Re-scanning is cheap since `enqueue()` de-duplicates.

## Config — `/opt/kb-bridge/kb-bridge.env` (mode 600)

| Variable | Default | Notes |
|---|---|---|
| `KB_DB_PATH` | `/opt/kb-bridge/kb-bridge.db` | SQLite queue + mappings |
| `KB_BIND` / `KB_PORT` | `0.0.0.0` / `8555` | **bind to the LAN address in production** |
| `KB_PATH_TOKEN` | generated | the secret in the URL path |
| `KB_LITELLM_URL` | `http://127.0.0.1:4000` | co-located |
| `KB_LITELLM_MASTER_KEY` | — | **must start with `sk-`** |
| `KB_BUDGET_DURATION` | *(empty)* | e.g. `1mo` for a monthly reset |
| `KB_KILLBILL_URL` | *(empty)* | set to enable verification + sweep |
| `KB_KILLBILL_API_KEY` / `_API_SECRET` | *(empty)* | per-tenant Kill Bill credentials |
| `KB_KILLBILL_USER` / `_PASSWORD` | *(empty)* | basic auth for the REST API |
| `KB_VERIFY` | `1` | **leave at 1.** Never grant a budget on an unverified event |
| `KB_RECV_BUSY_TIMEOUT_MS` | `250` | receiver fail-fast on lock contention |
| `KB_MAX_CONCURRENT` | `32` | receiver in-flight request cap |
| `KB_RECV_SLOT_WAIT_SECONDS` | `0.15` | wait for a slot before shedding |
| `KB_SWEEP_MAX_PAGES` | `20` | page cap per sweep run |
| `KB_SWEEP_INTERVAL_SECONDS` | `900` | markdown sleep between sweeps |
| `KB_MAX_ATTEMPTS` | `8` | then park as `failed` |

## Verification

All runs on VM205, 2026-09-18. LiteLLM state was always read back independently through `/budget/info` — never taken from this program's own log lines.

**Transport** — 25 sequential payloads: min 23 ms / p50 25 ms / p95 82 ms.
**Burst** — 60 simultaneous payloads: **60 × 200, zero lost, worst case 751 ms** (20× margin against the 15 s timeout). Before hardening: 9 failures at 5023 ms.
Wrong token → `404` (no endpoint disclosure). Replay → `duplicate: true`. Oversized body → `413`.

**Behaviour — 15/15 checks passed** against a mock Kill Bill plus 9/9 on the live LiteLLM path:

- sweep picks up the *one* fully-paid invoice and skips partial (`balance > 0`) and `DRAFT` ones
- watermark advances on a complete walk; a second sweep enqueues nothing
- verification **accepts** a genuinely paid invoice → budget `0.0 → 5.0`, confirmed by LiteLLM
- verification **refuses** a partially-paid invoice (`balance=12.5`) — budget unchanged
- verification **refuses** a `DRAFT` invoice — `not committed`
- verification **refuses** an invoice owned by a different account
- replay → `attempts=1`, `5.0 → 5.0` (no double-apply)
- cancel event → budget `0.0`

### What the re-audit found

The first version of this bridge passed 9/9 and was still wrong in three places. All three were invisible until the moment Kill Bill credentials were configured, and all three would have failed *silently*:

1. **Verification was broken.** It read `Invoice.paidAmount` — a field that exists in **no Kill Bill schema** — and accepted a `"PAID"` invoice status, which is not in the enum (`DRAFT | COMMITTED | VOID`). Every event would have been refused, forever, while logging a plausible-looking refusal reason.
2. **The sweep was broken.** It parsed `Payment.status` and `Payment.invoiceId`; a `Payment` has neither (status lives on `PaymentTransaction`). It would have matched zero payments forever *and reported success*.
3. **The sweep cursor was incoherent.** It stored the count of our own event rows and reused it as a Kill Bill payment offset.

Also fixed: the receiver stalled 5 s under a 60-request burst with 15% failures; the sweep's synthetic `tenantId` broke de-duplication against the webhook path; and the receiver spawned unbounded threads under a `MemoryMax` cap.

## Known gaps

- **`SUBSCRIPTION_CHANGE` is not handled.** Deciding the new budget needs a subscription→plan lookup against Kill Bill. Until that exists a plan change leaves the budget at the old value until the next payment. It is marked `skipped` with an explicit reason rather than silently ignored.
- **The bus thread count is inferred, not measured on `.104`.** Upstream's shipped default is `nbThreads=1` and our deploy sets nothing, but the running container's effective config has not been read directly (no SSH access to `.104` at time of writing).
- **One live proof is still owed:** that a tenant has exactly ONE callback URL. Proven at four code layers, but not yet observed on a real tenant — `/1.0/kb/tenants/{tenantId}` has no DELETE, so a throwaway tenant would be permanent.

## Still to do

1. **Create the tenant on `.104`**, then fill in `KB_KILLBILL_*` → verification and the sweep go live.
2. **Register the callback per tenant** and confirm one URL per tenant live.
3. **Firewall `:8555`** to the Kill Bill host only. It must **REJECT, not DROP** — a dropped packet makes Kill Bill wait the full 15 s, whereas a refused connection costs nothing.
4. **Set the real plan budgets** — the seeded `basic 5 / pro 20 / business 100` are placeholders.
5. **Decide `KB_BUDGET_DURATION`** (monthly reset) once pricing is settled.
