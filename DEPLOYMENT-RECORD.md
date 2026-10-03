# Deployment record — plugins + events retention

**Date:** 2026-10-03 · Records the installed plugins (C2) and the events-retention policy (C3) so the
`.104` box is rebuildable from this repo.

---

## Installed plugins (C2)

Both are loaded by dropping the jar into the mounted `bundles/plugins` dir (FileInstall watches it —
no `kpm install` on a versioned image). The `<version>/` level is MANDATORY.

| Plugin | Version | Jar path (on `.104`) | Tenant config (`tenant_kvs`) |
|---|---|---|---|
| **Stripe** | `8.0.4` | `plugins/java/stripe-plugin/8.0.4/stripe-plugin-8.0.4.jar` | `PLUGIN_CONFIG_killbill-stripe` = `org.killbill.billing.plugin.stripe.apiKey=${env:STRIPE_API_KEY}` (key value lives in `/opt/killbill/.env`, mode 600 — never in the DB) |
| **Email notifications** | `0.8.6` | `plugins/java/email-notifications/0.8.6/…` | `PLUGIN_CONFIG_killbill-email-notifications` — SMTP via Resend (`smtp.resend.com:465`), `defaultSender`, `defaultEvents=INVOICE_PAYMENT_SUCCESS,INVOICE_PAYMENT_FAILED` |

- Stripe SHA1 (verified on-box): `93523b1751987432964b51b5892903ad8e2db9ec`.
- Verify a plugin actually loaded via the OSGi boot log (`docker logs killbill | grep PluginFinder`),
  **never** via `plugin_identifiers.json` (stays `{}` while plugins serve).

---

## Events retention (C3)

- `kb-bridge-archive.service` takes an **append-only snapshot** of the bridge `events` table
  (never modifies the live table). It is currently **inactive/dead** — no timer drives it.
- **Gap (flagged, not blocking):** there is **no prune policy** for the live `events` table. It grows
  unbounded, and rows 1–218 already vanished at some point with no delete path (an unreproduced reset).
- **Policy to adopt (P10):** archive snapshot (enable a timer for `kb-bridge-archive`), then prune
  live rows older than N days, with a documented retention window. Do not prune before archiving.

---

## Compose drift (C1) — fixed

`KB_org_killbill_invoice_emailNotificationsEnabled: "true"` was present on `.104` but missing from
`setup-killbill.sh`. Added 2026-10-03 so a rebuild preserves invoice email.
