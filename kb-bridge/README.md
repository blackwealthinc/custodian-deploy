# kb-bridge — Kill Bill → LiteLLM budget bridge

Turns Kill Bill billing events into LiteLLM budget changes.

```
Kill Bill (billing engine, .104)
      │  POST  http://192.168.50.205:8555/kb/events/<token>
      ▼
┌──────────────────────────────────────────────────────────┐
│ VM205 (co-located with LiteLLM)                          │
│                                                          │
│  kb-bridge-receiver   accept → persist → 200  (<100 ms)  │
│           │                                              │
│           ▼   SQLite queue (WAL)                         │
│  kb-bridge-worker     plan → budget → POST /budget/update│
│           │                                              │
│  kb-bridge-sweep.timer  every 15 min: catch missed events│
└───────────┬──────────────────────────────────────────────┘
            ▼
    LiteLLM 127.0.0.1:4000  →  enforces the budget per customer
```

No third-party Python packages. Stdlib only — VM205 has ~760 MiB free.

## Why it is shaped like this

Three facts from the Kill Bill source (tag `killbill-0.24.21`, the version on `.104`) drove the design. All were verified, not assumed.

**1. Kill Bill makes the HTTP call itself, on its event-bus thread, with a 15-second timeout.**
`PushNotificationListener.triggerPushNotifications` is `@Subscribe` + `@AllowConcurrentEvents` and calls `doPost(..., TIMEOUT_NOTIFICATION, 0)` **synchronously**; `TIMEOUT_NOTIFICATION = 15`. The official docs' own sample log shows the thread name `th='bus_events-th'`.

> So the receiver must **ack in milliseconds**. It does nothing but persist the event and return 200. All real work happens in the worker, off the billing thread. Measured: **p50 25 ms, p95 82 ms** — ~160× headroom.

**2. There is exactly ONE callback URL per tenant, and Kill Bill sends no auth header.**
Callbacks are a *single-value* tenant KV (`PUSH_NOTIFICATION_CB(true)`); `DefaultTenantDao.addTenantKeyValue` runs `deleteFromTransaction` when the key is single-valued, so a second `POST` **replaces** the first. And `doPost` sets only `User-Agent: KillBill/1.0` and `Content-Type`.

> So the shared secret has to live in the **URL path**, and it is a noise filter rather than real auth. And because one URL serves all events for a tenant, routing must fan out *inside* the receiver.

**3. Delivery is at-least-once, retries are bounded, and events can be lost.**
Non-2xx is retried from a DB-backed queue on a per-tenant schedule (default `15m,30m,2h,12h,1d`), then stops ("Max attempt number reached") — confirmed by the maintainers' own `TestPushNotification` tests.

> So the consumer must be **idempotent** (it is — `UNIQUE(idem_key)` collapses retries), and there is a **sweep** to catch what retries gave up on.

**Security posture.** Kill Bill PR **#2183** (SSRF via callback URL) is **open and unmerged** and kills nothing by itself, but it means the callback URL is unvalidated and can point anywhere. Combined with unsigned webhooks on our side, the controls are: bind to the LAN, firewall to the Kill Bill host, keep the secret in the path — and **never trust an inbound event**. With `KB_VERIFY=1` the worker re-checks the invoice against Kill Bill before granting anything, and **fails closed** if Kill Bill is unreachable. A forged event therefore grants nothing.

## Install

Idempotent — safe to re-run. Reuses the existing token and DB.

```bash
curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/kb-bridge/install-kb-bridge.sh | sudo -E bash
```

It prints the exact callback URL to register. The bare token is also kept at `/opt/kb-bridge/.token` (mode 600).

**The install is currently run from a checked-out copy, because the script reads the LiteLLM master key out of the container** (`/tmp/.kbmk`) rather than accepting it on the command line — that keeps the secret out of shell history and out of any transcript.

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
| `INVOICE_PAYMENT_SUCCESS` | set the budget to `plans.max_budget` for the account's plan |
| `SUBSCRIPTION_CANCEL`, `SUBSCRIPTION_EXPIRED` | set the budget to `plans.on_cancel_budget` (default `0.0`) |
| anything else | acknowledged, marked `skipped` — not an error |
| unknown account | `skipped` with `no active mapping` — not an error |

Retries use exponential backoff (15 s → 15 min) up to `KB_MAX_ATTEMPTS`, then the row is parked as `failed` with the reason in `last_error`.

## Config — `/opt/kb-bridge/kb-bridge.env` (mode 600)

| Variable | Default | Notes |
|---|---|---|
| `KB_DB_PATH` | `/opt/kb-bridge/kb-bridge.db` | SQLite queue + mappings |
| `KB_BIND` / `KB_PORT` | `0.0.0.0` / `8555` | bind to the LAN address in production |
| `KB_PATH_TOKEN` | generated | the secret in the URL path |
| `KB_LITELLM_URL` | `http://127.0.0.1:4000` | co-located |
| `KB_LITELLM_MASTER_KEY` | — | **must start with `sk-`** |
| `KB_BUDGET_DURATION` | *(empty)* | e.g. `1mo` for a monthly reset |
| `KB_KILLBILL_URL` | *(empty)* | set to enable verification + sweep |
| `KB_KILLBILL_API_KEY` / `_API_SECRET` | *(empty)* | per-tenant Kill Bill credentials |
| `KB_KILLBILL_USER` / `_PASSWORD` | *(empty)* | basic auth for the REST API |
| `KB_VERIFY` | `1` | **leave at 1.** Never grant a budget on an unverified event |
| `KB_MAX_ATTEMPTS` | `8` | then park as `failed` |

## Verification (2026-09-18, on VM205)

Transport: 25 real Kill Bill payloads — **min 23 ms / p50 25 ms / p95 82 ms** against a 15,000 ms budget. Wrong token → `404` (no endpoint disclosure). Replay → `duplicate: true`. Oversized body → `413`.

Behaviour: **9/9 checks passed**, with the LiteLLM side read back independently via `/budget/info`:

- `KB_VERIFY=1` + no Kill Bill creds → event **refused**, budget still `0.0` (fail-closed proven)
- payment event → budget went to `5.0` (plan `basic`), confirmed by LiteLLM
- replay → `attempts=1`, budget `5.0 → 5.0` (no double application)
- cancel event → budget `0.0`
- `TENANT_CONFIG_CHANGE` → `skipped`, not an error

## Still to do

1. **Create the tenant on `.104`**, then fill in the `KB_KILLBILL_*` values → the sweep and verification go live.
2. **Register the callback per tenant** and confirm one URL per tenant live (the API has no tenant delete, so this needs a real tenant, not a throwaway).
3. **Firewall `:8555`** to the Kill Bill host only.
4. **Set the real plan budgets** — the seeded `basic 5 / pro 20 / business 100` are placeholders.
5. **Decide `KB_BUDGET_DURATION`** (monthly reset) once pricing is settled.
