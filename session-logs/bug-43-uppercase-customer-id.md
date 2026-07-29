# Bug #43 — Docker Compose rejects uppercase CUSTOMER_ID

**Date:** 2026-07-29
**Found by:** Line-by-line curl audit (Dell Deep Research removal audit)
**Severity:** Medium (script crashes, but lowercase workaround exists)
**Status:** Fixed

## Root Cause

`setup-custodian-factory.sh` line 181 passes `$CUSTOMER_ID` directly to `docker compose -p`:

```bash
docker compose -p $CUSTOMER_ID -f docker-compose.custodian-factory.yml up -d
```

Docker Compose v2 **rejects uppercase characters in project names**. This is documented in:
- [docker/compose#9741](https://github.com/docker/compose/issues/9741) — "docker compose restricts project name, where the spec does not"
- [docker/compose#10512](https://github.com/docker/compose/issues/10512) — "Project name validation error is confusing"

## Trigger

Any CUSTOMER_ID with an uppercase letter:
- `CUSTOMER_ID=William` → crashes
- `CUSTOMER_ID=Gabriel` → crashes
- `CUSTOMER_ID=admin` → works (all lowercase)

## Error

```
ERROR: Invalid project name "William" — must match regex [a-z0-9]([a-z0-9_-]*[a-z0-9])?
```

## Fix

Use bash `${CUSTOMER_ID,,}` lowercase expansion on line 181 only:

```bash
docker compose -p "${CUSTOMER_ID,,}" -f docker-compose.custodian-factory.yml up -d
```

## Why only line 181?

- **Container names** (lines 195, 254): Docker container names allow uppercase `[a-zA-Z0-9]` — no fix needed
- **File names** (line 184): Linux filesystem supports uppercase — no fix needed
- **LiteLLM key alias** (line 36): Just a label — no fix needed
- **docker compose -p** (line 181): THIS is the only place Docker Compose project names are used

## Verification

- `docker compose -p william ...` → works
- `docker compose -p gabriel ...` → works
- `docker compose -p admin ...` → works (unchanged behavior)
- Container names `William-hermes`/`William-webui` still valid
