# Bug #44 — Race condition: fixed `sleep 15` before Hermes config

**Date:** 2026-07-29
**Found by:** Line-by-line curl audit (Deep Research filter audit)
**Severity:** Medium (script can fail on slow systems)
**Status:** Fixed

## Root Cause

Line 194 used `sleep 15` as a fixed delay before configuring Hermes:

```bash
log_step 'Step 5: Configure Hermes Routing'
sleep 15
HERMES_CONTAINER="$CUSTOMER_ID-hermes"
```

If the container takes longer than 15 seconds to start (slow disk, network image pull delay), the subsequent `hermes config set` commands fail with "container not found" or "connection refused."

## Fix

Replace fixed sleep with polling loop that waits for the Hermes API health endpoint:

```bash
log_step 'Step 5: Configure Hermes Routing'

# Wait for Hermes API to be ready (Bug #44 — poll, not fixed sleep)
HERMES_CONTAINER="$CUSTOMER_ID-hermes"
log_info "Waiting for Hermes API..."
for i in $(seq 1 30); do
  if curl -s http://localhost:${PORT:-8642}/v1/health 2>/dev/null | grep -q '"status"'; then
    break
  fi
  [ "$i" -eq 30 ] && { log_error "Hermes API not ready after 60s"; exit 1; }
  sleep 2
done
log_ok "Hermes API ready"
```

- Polls every 2 seconds, up to 30 attempts (60s max)
- Exits with clear error if not ready
- Uses the same `/v1/health` endpoint that Step 6 verifies
- References: Docker best practices — poll health endpoints, don't use fixed sleeps
