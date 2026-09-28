# Stripe plugin install runbook — Kill Bill `.104`

**Status:** OPERATIONAL RUNBOOK · created 2026-09-24 · **nothing executed yet — steps 1–2 staged only**
**Target:** `192.168.50.104` · `killbill/killbill:0.24.21` (Docker Compose, `/opt/killbill/`)
**Companion docs:** `catalog/E2E-paid-path-runbook.md` (the paid path this feeds) · `research/stripe-crypto-decisions-research-2026-09-18.txt` (option analysis)

---

## 0. WHY THIS DOC EXISTS — read §1 before touching anything

The obvious way to install a Kill Bill plugin (**`docker exec` + `kpm install`**) is **silently wrong on this box**, and the failure appears *after* everything looks successful.

**Evidence, all verified live on `.104` on 2026-09-24:**

1. **`docker diff killbill` proves the plugin directory is ephemeral:**
   ```
   A /var/lib/killbill/bundles/plugins
   A /var/lib/killbill/bundles/plugins/plugin_identifiers.json
   ```
   `A` = **added** — these exist **only in the container's writable layer.** (By contrast `bundles/platform/` is absent from the diff → it is baked into the image.)

2. **The container has NO volume mounts.** `docker inspect killbill` → `NO MOUNTS`; the image declares `Config.Volumes: null`. Only `killbill-db` is persisted (`killbill_db-data` → `/var/lib/mysql`).

3. **`killbill/killbill:0.24.21` does NOT run `kpm install` on startup.** The entire startup script:
   ```bash
   #!/bin/bash
   originalfile=$KILLBILL_INSTALL_DIR/config/shiro.ini.template
   cat $originalfile | envsubst '${KB_ADMIN_PASSWORD}' > $KILLBILL_INSTALL_DIR/config/shiro.ini
   exec /usr/share/tomcat/bin/catalina.sh run
   ```
   The Kill Bill Docker README's *"It runs `kpm install` on startup"* refers to **`killbill/killbill:latest` (the empty image)** — **not this versioned tag.** The 32 `kpm` lines in the boot log are `FileInstall` loading the KPM **platform** bundle, not an install.

4. **The failure is silent.** Tenant/plugin config lives in the **database**, which **is** persisted (there is no tenant config on disk — `/var/lib/killbill/config/` holds only `shiro.ini`). So after a recreate the config survives, the plugin **doesn't**, and `/plugins/killbill-stripe/checkout` returns **404** while every config page looks healthy.

**The trigger is container RECREATION, not restart.** `docker restart` / `stop`+`start` preserve the writable layer — proven by this container: `Created=2026-09-09 · RestartCount=0`, i.e. **it survived all 8 host crashes with its layer intact.** Recreation happens on `docker compose up -d` after a config change, `docker compose down`, or `docker rm` — **and we must recreate the container to add the Stripe key to its environment.**

> **⇒ Never install a plugin imperatively on this box. Mount the plugin directory, then install.**

---

## 1. THE SAFE DESIGN (and the mount trap)

**Mount `bundles/plugins` — the CHILD directory. Never `bundles/` itself.**

`bundles/platform/` ships **inside the image** and holds the OSGi runtime:
```
killbill-platform-osgi-bundles-kpm-0.41.23.jar      (15 MB)
killbill-platform-osgi-bundles-logger-0.41.23.jar
killbill-platform-osgi-bundles-metrics-0.41.23.jar
```
Mounting an empty host directory over `bundles/` **shadows all three** → **Kill Bill fails to start.** This is the single most dangerous mistake available here.

| Path | Where it lives | Mount it? |
|---|---|---|
| `/var/lib/killbill/bundles/` | image (holds `platform/`) | ❌ **NEVER** |
| `/var/lib/killbill/bundles/plugins/` | **writable layer (ephemeral)** | ✅ **YES — this is The Fix** |
| `/var/lib/killbill/bundles/platform/` | image | ❌ leave alone |
| `/var/lib/killbill/kpm.yml` | writable layer | ⚠️ optional — but see note |

**How the plugin actually loads — ⚠️ CORRECTED 2026-09-28.** An earlier version of this file said
`FileInstall` "watches the bundles tree and loads any jar placed in it", and concluded that dropping
the jar into `plugins/` was sufficient. **That was WRONG, and it is why the recorded
"Stripe Step 1: DONE" was never effective.** `FileInstall` only handled the `platform/` bundles; a
plugin jar goes through a different scanner, `PluginFinder`, which **skipped our jar**:

```
WARN org.killbill.billing.osgi.pluginconf.PluginFinder
  Skipping entry stripe-plugin in directory /var/lib/killbill/bundles/plugins/java
```

**PluginFinder requires TWO directory levels — a plugin dir containing VERSION dirs:**

```
<bundle.install.dir>/plugins/java/<pluginName>/<version>/<jar>.jar
e.g.
/var/lib/killbill/bundles/plugins/java/stripe-plugin/8.0.4/stripe-plugin-8.0.4.jar
```

Read from `PluginFinder.loadPluginsForLanguage()`: it lists the plugin dir, then requires each entry
*inside* it to be a **directory** (`if (!curVersion.isDirectory()) { logger.warn("Skipping entry {}…") }`).
A jar sitting directly in the plugin dir is a non-directory entry → skipped, **silently apart from one
WARN**. Kill Bill's own test fixture (`TestPluginFinder.java`) builds exactly this shape:

```java
final File newPlugin = new File(pluginsJava, pluginName);
final File version   = new File(newPlugin, cur);            // a VERSION directory
final File jar       = new File(version, pluginName + ".jar");
```

Also: the plugin dir is named `<pluginKey>-plugin` (this is what the image's own ansible task and
`PluginNamingResolver` produce), and the mount target is still `bundles/plugins` — see the table above.

**Ownership matters here too:** `/var/lib/killbill/bundles/plugins` is `tomcat:tomcat` and the engine
expects to **write** into it. In the image `tomcat` is **uid:gid `1001:1001`**, so the host directory
must be `chown -R 1001:1001` (not `root:root`) or the engine can read the jar but cannot write its own
bookkeeping file.

**Note on `kpm.yml`:** it is inert on this image tag (nothing reads it at boot), so editing it alone
achieves **nothing**. Keep it accurate for documentation, but do not rely on it. `kpm install_java_plugin
stripe --destination=/var/lib/killbill/bundles` **is** a valid fallback (the image ships the command and
the container can reach Maven Central — verified `200`), but it is unnecessary once the layout is right.

---

## 2. ARTEFACT — verified before use

| Item | Value | Verified |
|---|---|---|
| Artifact | `org.kill-bill.billing.plugin.java:stripe-plugin:8.0.4` | ✅ Maven Central `<release>8.0.4</release>` |
| Jar URL | `https://repo1.maven.org/maven2/org/kill-bill/billing/plugin/java/stripe-plugin/8.0.4/stripe-plugin-8.0.4.jar` | ✅ HTTP 200 |
| **SHA1** | **`93523b1751987432964b51b5892903ad8e2db9ec`** | ✅ published at `<url>.sha1` |
| Compatibility | plugin `8.0.y` ↔ Kill Bill `0.24.z` | ✅ we run **0.24.21** |
| **Install 8.0.4, NOT 8.0.2** | `${env:…}` secrets exist **only** in 8.0.4 | ✅ source |
| Plugin DB tables | `stripe_hpp_requests`, `stripe_responses`, `stripe_payment_methods` | ✅ `ddl.sql` |

**Always checksum the downloaded jar against the published SHA1 before placing it.** Do not skip.

---

## 3. THE KEY — how it is held

- The plugin resolves `${env:STRIPE_API_KEY}` via `System.getenv()` — verified at `StripeConfigProperties.java:80`, and `StripeConfigPropertyResolver` **throws** if the variable is unset (so a misconfiguration fails loudly, not silently).
- ⚠️ **Only `apiKey` and `publicKey` pass through the resolver.** Every other property uses plain `getProperty` — so `chargeStatementDescriptor` **cannot** come from an env var.
- The key goes in **`/opt/killbill/.env`**, mode **600**, referenced as `${STRIPE_API_KEY}` by Compose. **Never in `docker-compose.yml`, never in git, never in the database.**
- ⚠️ `docker update --env-add` is **broken** — env changes require a Compose edit + recreate.
- **Rotation:** the currently-issued live key was transmitted over chat and is considered **exposed**. Rotate it, then replace with a **least-privilege** key (7 permissions, not full write).

---

## 4. STEPS

### Step 1 — Stage (no downtime, zero risk) ✅ **EXECUTED 2026-09-24 — EVIDENCE BELOW**
```bash
sudo mkdir -p /opt/killbill/bundles/plugins/java/stripe-plugin/8.0.4
sudo cp -n /opt/killbill/docker-compose.yml /opt/killbill/docker-compose.yml.bak-<date>
# download + CHECKSUM
curl -sL -o /tmp/stripe-plugin-8.0.4.jar <jar-url>
echo "93523b1751987432964b51b5892903ad8e2db9ec  /tmp/stripe-plugin-8.0.4.jar" | sha1sum -c -
# the TWO-level layout PluginFinder requires (see §1) -- NOT a flat plugins/ jar
sudo mv /tmp/stripe-plugin-8.0.4.jar /opt/killbill/bundles/plugins/java/stripe-plugin/8.0.4/
# uid:gid 1001:1001 == the image's tomcat user; root:root would block the engine
sudo chown -R 1001:1001 /opt/killbill/bundles/plugins
```

**What was actually done, and the evidence:**

| Item | Result |
|---|---|
| Compose backup | `/opt/killbill/docker-compose.yml.bak-20260924-070726` (1217 B — identical size to the original) ✅ |
| Persistent dir | `/opt/killbill/bundles/plugins/` created ✅ |
| Jar downloaded | **21,797,779 B** (21.8 MB) ✅ |
| **SHA1** | published `93523b17…d8e2db9ec` == downloaded `93523b17…d8e2db9ec` → **MATCH** ✅ |
| Jar integrity | 15,037 zip entries · `MANIFEST.MF` present · **42 `plugin/stripe/*.class`** · **`ddl.sql` present** ✅ |
| Placed 2026-09-24 | `/opt/killbill/bundles/plugins/stripe-plugin-8.0.4.jar` ⚠️ **flat — WRONG LEVEL, never loaded** |
| **Placed (fixed) 2026-09-28** | `/opt/killbill/bundles/plugins/java/stripe-plugin/8.0.4/stripe-plugin-8.0.4.jar` ✅ **loaded** |
| `.env` | **deliberately NOT created** — see note |
| **Downtime 09-24** | **ZERO.** `killbill` `StartedAt=2026-09-22T15:11:54Z`, `RestartCount=0`, containers `Up 45 hours` — unchanged ✅ |

> ⚠️ **The 2026-09-24 "Step 1: DONE" was NOT effective.** The jar was in the right volume at the wrong
> *level*, and `PluginFinder` skipped it — logged once, as a WARN, at every boot. The compose mount was
> also never added at that time, so the container could not even see it. Both were fixed on **2026-09-28**
> (see Step 1b). **A checksum match proves the artifact, not the installation.**

> **Why no placeholder `.env`:** it needs the **rotated** key (Step 2). A placeholder would make Compose substitute an empty value, and the plugin's resolver **throws** on load. The file gets created in Step 2 with the real key.

> **`ddl.sql` ships inside the jar** — so if the 3 tables are missing after load, extract and apply without downloading anything:
> `unzip -p /opt/killbill/bundles/plugins/stripe-plugin-8.0.4.jar ddl.sql`

### Step 1b — THE LAYOUT FIX + MOUNT ✅ **EXECUTED 2026-09-28 — PLUGIN NOW LOADING**

This is the step that actually made the plugin work. Two changes, one recreate.

```bash
SUDO="sudo"          # on .104 sudo needs a password: use the SUDO_ASKPASS + sudo -A pattern
P=/opt/killbill/bundles/plugins
# 1. correct the layout: add the VERSION directory level PluginFinder requires
$SUDO mkdir -p $P/java/stripe-plugin/8.0.4
$SUDO mv $P/stripe-plugin-8.0.4.jar $P/java/stripe-plugin/8.0.4/
$SUDO chown -R 1001:1001 $P          # the image's tomcat uid:gid
$SUDO chmod 750 $P; $SUDO chmod 755 $P/java $P/java/stripe-plugin/8.0.4
# 2. mount the persistent child directory
#    (added to the killbill service in /opt/killbill/docker-compose.yml)
#      volumes:
#        - /opt/killbill/bundles/plugins:/var/lib/killbill/bundles/plugins
cd /opt/killbill && $SUDO docker compose up -d killbill     # ~15 s to healthy
```

**Evidence — before and after:**

| | Result |
|---|---|
| Compose backup | `/opt/killbill/docker-compose.yml.bak-plugin-20260928-191016` ✅ |
| Compose md5 | `0b0db347…` → `24183605…`; validated with `docker compose config -q` before applying ✅ |
| Compose diff | **one `volumes:` block on the `killbill` service only** — nothing else changed ✅ |
| Container | recreated; **`killbill-db` and `kaui` untouched (Up 6 days)** ✅ |
| Time to health | **~15 s** |
| Jar SHA1 after the move | `93523b1751987432964b51b5892903ad8e2db9ec` — **unchanged** ✅ |
| **Before (flat jar)** | `WARN PluginFinder Skipping entry stripe-plugin in directory …/plugins/java` ❌ |
| **After (version dir)** | `INFO PluginFinder Adding plugin stripe-plugin-8.0.4` ✅ |
| Payment registry | `INFO DefaultPaymentProviderPluginRegistry Registering service='killbill-stripe'` ✅ |
| Bundle state | `BundleEvent STARTED` ✅ |
| Engine healthcheck | `200`, body includes `KillbillPluginsHealthcheck: {"killbill-stripe":{"message":"Stripe OK"}}` ✅ |
| Plugin's own servlet | `GET /plugins/killbill-stripe/healthcheck` → **200** `{"message":"Stripe OK"}` ✅ |
| Data | accounts=2, subscriptions=2, invoices=2, overdue config row=1 — all intact ✅ |
| Errors | **none** (the only `ERROR` in the window was our own curl to `/plugins/killbill-stripe/`, a missing route) ✅ |

> **Scope note:** `docker compose up -d killbill` recreates **only** that service. Always confirm with
> `docker ps` that `killbill-db` and `kaui` kept their original uptime — if they were recreated too,
> something else in the compose changed unexpectedly.

### Step 2 — Key file
```bash
sudo install -m 600 /dev/null /opt/killbill/.env
# then write:  STRIPE_API_KEY=<key>
```
⚠️ **Do not paste the key on a command line** — it lands in shell history. Use an editor, or `install -m 600`.

### Step 3 — Compose change ⚠️ **HAS DOWNTIME (~1–2 min)**
Add to the `killbill` service:
```yaml
    environment:
      # … existing vars unchanged …
      STRIPE_API_KEY: ${STRIPE_API_KEY}
    volumes:
      - /opt/killbill/bundles/plugins:/var/lib/killbill/bundles/plugins   # child dir ONLY
```
Then: `cd /opt/killbill && sudo docker compose up -d killbill`

### Step 4 — Verify (all in order)
1. **⚠️ CORRECTED: `plugin_identifiers.json` is NOT the success signal.** It is written by the KPM
   *CLI*, not by the runtime scanner, and it stayed `{}` even while the plugin loaded and ran
   (verified 2026-09-28). Reading it and expecting it to change produces a **false negative**. The
   real signal is the boot log:
   ```bash
   sudo docker logs killbill 2>&1 | grep -aE "Adding plugin|BundleEvent STARTED|Registering service='killbill-stripe'"
   ```
   A healthy load shows all of:
   ```
   INFO  PluginFinder   Adding plugin stripe-plugin-8.0.4
   INFO  FileInstall    Installing Java bundle for plugin stripe-plugin from …/8.0.4/stripe-plugin-8.0.4.jar
   INFO  KillbillActivatorBase  OSGI bundle='org.kill-bill.billing.plugin.java.stripe-plugin' received START command
   INFO  DefaultPaymentProviderPluginRegistry  Registering service='killbill-stripe'   ← the one that matters
   INFO  KillbillLogWriter  [org.kill-bill.billing.plugin.java.stripe-plugin] BundleEvent STARTED
   ```
   And a `WARN … Skipping entry <dir> in directory …/plugins/java` means the **layout is wrong** (§1).
2. **⚠️ Do NOT test `/plugins/*` with a bare curl.** An invented plugin path returns the **identical `400` + NullPointerException** as a real one — the 400 means nothing. Also note that curling the servlet's
   **root** (`/plugins/killbill-stripe/`) returns **404 and logs an ERROR** in Jooby — that is a *missing
   route*, not a broken plugin, and it will look alarming in the log if you go looking for errors.
   The plugin's **own** healthcheck **does** answer (verified 2026-09-28):
   | Path | Result |
   |---|---|
   | `/1.0/healthcheck` | **200** — and its body names the plugin: `KillbillPluginsHealthcheck: {"killbill-stripe": {"message": "Stripe OK"}}` ✅ |
   | `/plugins/killbill-stripe/healthcheck` | **200**, body `{"message":"Stripe OK"}` ✅ (the plugin's own servlet) |
   | `/plugins/killbill-stripe/` (root) | 404 + an ERROR log line — expected, not a fault |
   | `/healthcheck` | 404 ❌ (does not exist — easy to guess wrong) |
   | `/1.0/kb/healthcheck` | 401 (needs auth) |
   | `/1.0/kb/plugins` | **404 on 0.24.21** — that route does not exist on this tag ❌ |
3. **DDL applied?** Check for the 3 tables in the `killbill` database. **Whether the KPM/flyway flow applies plugin DDL is UNVERIFIED** — if the tables are missing, apply `ddl.sql` manually.
   ✅ **Already satisfied on `.104`** (verified 2026-09-28): `stripe_hpp_requests`, `stripe_responses`,
   `stripe_payment_methods` all present with every column, the `is_default` migration column, and all
   unique/non-unique indexes matching `ddl.sql`.
4. **⚠️ THE CRITICAL TEST — recreate a SECOND time** and confirm the plugin is still registered. This is the only thing that proves the ephemeral-layer trap is actually fixed. Skipping it means hoping.
   ✅ **PASSED on `.104` 2026-09-28** with `docker compose up -d --force-recreate killbill`: the plugin
   re-registered itself in both registries and emitted `BundleEvent STARTED` again.

### Step 4b — ⚠️ WHAT THE HEALTHCHECK DOES AND DOES NOT PROVE (falsification-tested 2026-09-28)
Three states, all measured on `.104`:

| Call | Result |
|---|---|
| `GET /plugins/killbill-stripe/healthcheck` with **no tenant headers** | **200 `{"message":"Stripe OK"}`** — meaningless: it says OK with no config present at all |
| … **with tenant auth**, no plugin config uploaded | **503 `Stripe error: No API key provided`** — detects the *absence* of config |
| … **with tenant auth**, a **deliberately invalid** api key | **200 `{"message":"Stripe OK"}`** — does **not** detect a bad key (re-tested after a 10 s wait, so this is not a cache) |

**Conclusion: the healthcheck answers "is a key configured?", never "does the key work?"**
`StripeHealthcheck.pingStripe()` builds `RequestOptions`; Stripe's SDK throws "No API key provided"
for a null/blank key, but an authentication *failure* is never surfaced. **A green healthcheck must
never be reported as "Stripe is working."**

The only proof a key works is a real Stripe API call — verified independently on 2026-09-28 by calling
`GET https://api.stripe.com/v1/balance` and `/v1/account` directly with the key (200, `livemode: true`,
`acct_1TkRw5BSBjZGow5B`, charges enabled).

### Step 5 — Tenant config
`POST /1.0/kb/tenants/uploadPluginConfig/killbill-stripe` with
`org.killbill.billing.plugin.stripe.apiKey=${env:STRIPE_API_KEY}`

⚠️ **UPLOAD THE BODY WITH NO TRAILING NEWLINE.** `StripeConfigPropertyResolver`'s env pattern is
**anchored** (`^\$\{env:([^}]+)}$`). A body ending in `\n` stores the value as
`${env:STRIPE_API_KEY}\n`; the pattern does not match, the key is never resolved, and the plugin
reports **503** with no other clue. Measured 2026-09-28: **64 bytes → 503, 63 bytes → 200.**
Use `printf '%s'` (not `echo`, not a heredoc).

**Verified live 2026-09-28:** the config is stored as `tenant_kvs.tenant_key = PLUGIN_CONFIG_killbill-stripe`;
the secret itself never enters the database. The key is supplied out-of-band:

1. `printf 'STRIPE_API_KEY=<key>' > /opt/killbill/.env` (mode 600, root)
2. one line in `docker-compose.yml`: `STRIPE_API_KEY: ${STRIPE_API_KEY}`
3. `docker compose up -d killbill` — the container then carries `STRIPE_API_KEY` (verified: len 107, `rk_live_`)

ℹ️ **Re-uploading does NOT overwrite — it inserts and deactivates.** Each `uploadPluginConfig` call adds a new
`tenant_kvs` row and sets `is_active=0` on the previous ones, so the table accumulates history and exactly one
row is ever active (verified: 6 uploads → 6 rows, 1 active). That is correct behaviour, not a leak — but it
means **do not panic at a multi-row count; check `is_active`.** (Same shape as the two `CATALOG` rows, where KB
instead *merges* all active rows — different mechanism, so check the specific key.)

**The complete set of keys the plugin reads** (extracted from the 8.0.4 jar, verified 2026-09-28):

| Key (`org.killbill.billing.plugin.stripe.` + …) | Purpose |
|---|---|
| `apiKey` | **required** — the Stripe secret key |
| `publicKey` | publishable key (used by the hosted-checkout servlet) |
| `apiBase` | override the Stripe API base (test/proxy) |
| `chargeDescription` / `chargeStatementDescriptor` | what the customer sees on the statement |
| `connectionTimeout` / `readTimeout` | HTTP timeouts |
| `proxyHost` / `proxyPort` | outbound proxy |
| `pending` / `pendingPaymentExpirationPeriod` / `pendingHppPaymentWithoutCompletionExpirationPeriod` | pending-payment expiry |
| `cancelOn` | cancel behaviour |

**The plugin registers itself as `killbill-stripe`** — that is the `pluginName` the payment API expects
when creating a payment method.

### Step 6 — Prove it with real money, in order
1. `POST /plugins/killbill-stripe/checkout?kbAccountId=<id>&successUrl=…&cancelUrl=…`
   ⚠️ **NOT YET WORKING (2026-09-28):** with `kbAccountId` + `kbInvoiceId` + `successUrl` + `cancelUrl`
   this returns **400 `java.lang.NullPointerException`**. The servlet reads `kbAccountId`/`kb_account_id`,
   `kbInvoiceId`/`kb_invoice_id`, `successUrl`/`success_url`, `cancelUrl`/`cancel_url`. Needs investigation
   before the checkout flow can be exercised — do not assume the parameter set above is complete.
2. **Open the returned URL in a real browser** — confirm the hosted page renders
3. Card entry runs in **`mode: "setup"` → ⚠️ charges $0.** Save the card; confirm it appears in Kill Bill
4. Registering the card needs **`addPaymentMethod?pluginProperty=sessionId=cs_…`** or `PUT /accounts/{id}/paymentMethods/refresh` — *which of these Kaui does for us is UNVERIFIED*
5. **Then** one small **real** charge, on our own card, and **refund it**

---

## 5. ROLLBACK

```bash
sudo cp /opt/killbill/docker-compose.yml.bak-<date> /opt/killbill/docker-compose.yml
cd /opt/killbill && sudo docker compose up -d killbill      # ~1–2 min
```
Removing the plugin: delete the jar from `/opt/killbill/bundles/plugins/`, recreate. Config in the DB can be left (harmless) or removed.

---

## 6. VERIFIED vs UNVERIFIED (honest ledger)

**✅ Verified from source / live evidence**
- `bundles/plugins` is in the writable layer (`docker diff`)
- No mounts; only the DB persists
- No `kpm install` at boot on `0.24.21` (4-line startup script; README's claim targets `:latest`)
- `FileInstall` auto-loads jars from the bundles tree
- `bundles/platform/` is image-provided — mounting the parent breaks startup
- `${env:}` resolves for **apiKey/publicKey only**, and throws when unset
- Plugin 8.0.4 + SHA1 published; `0.24.21` compatibility
- The plugin's Stripe surface, from full source: `Customer.create/retrieve`, `Session.create`, `PaymentIntent.create/retrieve/getCharges`, `SetupIntent.retrieve`, `PaymentMethod.attach/list/retrieve`, `Charge.retrieve/search`, `Refund.create`, `Token.retrieve`, `Source.retrieve`
- The plugin sets **no** API version — `stripe-java` fixes it internally

**⚠️ NOT verified — do not assume**
- Whether plugin **DDL** is auto-applied, or must be run by hand
- Whether **Kaui** performs the post-checkout `addPaymentMethod`/`refresh` step, or we must build it
- The **`KB_ADMIN_PASSWORD`** env var is **not present** in the container, yet `killbill.sh` substitutes it into `shiro.ini` — **possible blank admin password. Security item, unverified.**
- The plugin's **restricted-key permission set** — my first list was incomplete (missed `.detach(`, `.cancel(`, `.confirm(`, `.update(`×4). Stripe's 403 **names the missing permission**, so we iterate.

---

## 7. CHANGELOG

| Date | Change |
|---|---|
| 2026-09-24 | Created. Records the ephemeral-plugin trap and its evidence; the child-directory-only mount rule; the `FileInstall` mechanism; the verified artefact + SHA1; the key-handling rules; the 6 steps; rollback; and the honest verified/unverified split. Steps 1–2 staged, nothing else executed. |
