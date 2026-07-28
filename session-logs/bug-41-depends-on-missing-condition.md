# Bug #41 — PullMD depends_on Missing condition: service_healthy

**Date:** 2026-07-28
**Severity:** Medium
**Found By:** WebDev (self-audit, line-by-line review)
**Status:** Fixed

## Summary

`docker-compose.pullmd.yml` has:

```yaml
depends_on:
  - trafilatura
```

This is equivalent to `condition: service_started` — Docker starts `pullmd` the moment the `trafilatura` container *starts*, not when it's *ready*. If PullMD sends its first extraction request before uvicorn is listening on port 8001, it gets `ECONNREFUSED`.

The SearXNG compose uses the correct defensive pattern:

```yaml
depends_on:
  valkey:
    condition: service_healthy
```

## Root Cause

The trafilatura service had no healthcheck defined, so `condition: service_healthy` couldn't be used. The pullmd healthcheck was verified against source (PullMD server.js line 970: `GET /api/stats`) but trafilatura was left unchecked.

## Fix

1. Added healthcheck to the `trafilatura` service using the verified `/health` endpoint:
```yaml
healthcheck:
  test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')"]
  interval: 10s
  timeout: 5s
  retries: 3
  start_period: 5s
```

2. Updated `pullmd` depends_on to wait for healthy:
```yaml
depends_on:
  trafilatura:
    condition: service_healthy
```

## Source Verification

- Trafilatura sidecar `GET /health` confirmed at: https://github.com/AeternaLabsHQ/pullmd/blob/main/trafilatura-sidecar/app.py (line 16)
- Returns `{"ok": true, "trafilatura": "x.x.x"}`
- Python runtime confirmed in base image: `python:3.12-slim`
