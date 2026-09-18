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

**2. And there is only ONE bus thread — measured on `.104`, not inferred.** Kill Bill's shipped config sets:
```
org.killbill.persistent.bus.main.nbThreads=1
org.killbill.persistent.bus.main.queue.capacity=1000
```
Confirmed against the running container: the only `KB_*` bus override present is
`KB_org_killbill_notificationq_main_queue_mode=POLLING` — `nbThreads` is untouched. So a stalled callback cannot just slow one worker — it can **stop all event dispatch**. This is why the receiver's latency ceiling is treated as a hard safety property, not a performance nicety.

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

**About `audit` — corrected 2026-09-18.** An earlier version of this file said
"Spec ≠ implementation" and told you never to send `audit`. **That was wrong.**

`audit` is not a string. It is an enum:

```java
@QueryParam(QUERY_AUDIT) @DefaultValue("NONE") final AuditMode auditMode
// AuditMode: this.level = AuditLevel.valueOf(auditModeString.toUpperCase());
```

An invalid value throws during JAX-RS parameter conversion, and the JAX-RS spec
**requires a 404** in that case. So the 404 was correct behaviour — not a Kill
Bill bug. Measured live on `.104`:

```
audit=NONE  -> 200      audit=true  -> 404
audit=FULL  -> 200      audit=1     -> 404
audit=MINIMAL -> 200    audit=bogus -> 404
audit= (empty) -> 200   (empty skips conversion, falls back to @DefaultValue)
```

Two consequences worth keeping: the parameter is perfectly **usable** as
`audit=NONE|FULL|MINIMAL`, and this is **not endpoint-specific** — 64 live
endpoints declare `audit` and all behave identically. We simply omit it,
because `NONE` is already the default.

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

4. **A fourth one, found only by wiring it up:** the sweep sent `audit=true` to `/1.0/kb/invoices/pagination`, and the live engine answers that with a **404 HTML page**. Nothing caught this until the sweep ran against the real engine — the mock had been too permissive, and has since been made to reproduce the 404 so the suite can catch it.

   **The cause I gave at the time was wrong, and is corrected above** (see §"About `audit`"). The 404 is *correct* JAX-RS behaviour for an invalid enum value, not a Kill Bill defect, and `audit=NONE|FULL|MINIMAL` all return 200. Worth keeping as a lesson about *two* different failures at once: the sweep really was broken, but my explanation of why was a confident guess that survived because the fix worked either way. A fix that works for the wrong reason is not a verified fix.

### Live wiring (2026-09-18)

Tenant `custodian` (externalKey `custodian-demo`) created on `.104` via `POST /1.0/kb/tenants`, id `fc46a7f4-1631-463d-b03e-dc35266724ad`. The callback was registered on it, and **Kill Bill delivered a real event**:

```
recv eventType=TENANT_CONFIG_CHANGE objectId=0374349f-... fresh=True
worker -> status=skipped  "not actionable: TENANT_CONFIG_CHANGE"   (correct)
```

That exercises the whole path: Kill Bill → `192.168.50.205:8555` → SQLite queue → worker. The sweep also ran live for the first time (`pages=1 scanned=0 new=0`), authenticating and completing against the real engine.

**The one-callback-per-tenant claim is now proven live**, on a real tenant:

| Action | Result |
|---|---|
| register URL ONE → GET | 1 value = URL ONE |
| register URL TWO → GET | 1 value = **URL TWO** — replaced, not appended |
| re-register the same URL twice | still 1 entry (provisioning is idempotent) |
| DELETE → GET | `204`, then `[]` — clears the whole key |

### Kill Bill gotchas discovered by doing it

- **A tenant's `apiSecret` is unrecoverable.** The API returns `apiSecret: null` on read, and the DB stores a salted hash (measured: 88-char hash + 24-char salt). Lose it and the tenant is orphaned forever — there is no tenant DELETE. **Persist the secret the instant the create returns.**
- **The tenant cache is in-memory and goes stale.** Deleting rows behind the engine's back leaves it serving a deleted tenant, and that stale entry makes re-creating the same api key return `409`. `DELETE /1.0/kb/admin/cache/tenants` only works **once a valid tenant context exists** (root basic auth alone gets `401`); otherwise a `docker restart killbill` flushes it.
- **`useGlobalDefault` on tenant create** defaults to `false`, giving the tenant an explicit *empty* catalog (`catalogUserApi.createDefaultEmptyCatalog`). Uploading our own catalog works either way, so the default is the clean state.
- Root API auth here is `admin:password` (shiro.ini: `admin = password, root`; role `root = *:*`). Our compose sets no auth config, so these are image defaults.

## Known gaps

- **`SUBSCRIPTION_CHANGE` is not handled.** Deciding the new budget needs a subscription→plan lookup against Kill Bill. Until that exists a plan change leaves the budget at the old value until the next payment. It is marked `skipped` with an explicit reason rather than silently ignored.
- **Per-tenant credentials are not modelled.** `KB_KILLBILL_*` is a single credential set, which is fine for one tenant. With several resellers, each tenant needs its own credentials for verification and sweeping — and `NotificationJson` carries **no `tenantId`**, so the webhook alone cannot say which tenant sent it. The intended fix is a **per-tenant callback URL**: register `…/kb/events/<tenant-specific-token>` with each tenant's credentials, so the path identifies the tenant. One URL per tenant already, so this costs nothing architecturally.
- **The bridge's `:8555` is still open to the LAN.** Firewall to the Kill Bill host, and **REJECT, not DROP**.

## Still to do

1. **Author and upload the Kill Bill catalog** — the tenant currently has an empty one, so no subscription or invoice can exist yet. Validate with `POST /1.0/kb/catalog/xml/validate` before uploading.
2. **Set the real plan budgets** — the seeded `basic 5 / pro 20 / business 100` are placeholders, and `plans` maps a Kill Bill plan name to a dollar ceiling.
3. **Map accounts** once accounts exist: `kb_bridge.py map --account-id <uuid> --budget-id <litellm-budget>`.
4. **Firewall `:8555`.**
5. **Decide `KB_BUDGET_DURATION`** (monthly reset) once pricing is settled.
6. **Add the per-tenant credential model** before onboarding a second reseller.
