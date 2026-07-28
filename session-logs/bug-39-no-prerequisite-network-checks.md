# Bug #39 — No Prerequisite Network Checks in Factory Script

**Date:** 2026-07-28
**Severity:** Medium
**Found By:** WebDev (self-audit)
**Status:** Fixed

## Summary

The `setup-custodian-factory.sh` script references `searxng-net` and `extractor-net` as external Docker networks, but Docker Compose fails with "network X not found" if the prerequisite services haven't been deployed first. The deployment order (SearXNG → PullMD → Factory) is documented in comments but not enforced by the script.

## Root Cause

The factory's docker-compose.yml declares networks as `external: true`:

```yaml
networks:
  searxng-net:
    external: true
```

Docker Compose will refuse to start if the network doesn't exist. The script has a `log_warn` but doesn't block early — it proceeds and hits the Docker Compose error deep in Step 3.

## Fix

Added explicit network existence checks at the beginning of Step 3, before `docker compose up`:

```bash
# Verify prerequisite networks exist
for net in searxng-net; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
        log_error "$net not found — run the prerequisite scripts first:"
        log_error "  1. setup-searxng.sh    (creates searxng-net)"
        log_error "  2. setup-extractor.sh  (creates extractor-net, optional)"
        exit 3
    fi
    log_ok "$net found"
done
```

## Design Decision

- `extractor-net` is NOT required — PullMD is optional. The check only validates `searxng-net`.
- Fails fast with exit code 3 (distinct from other error codes) so the user knows exactly what's missing.
- Lists the prerequisite scripts in order.
