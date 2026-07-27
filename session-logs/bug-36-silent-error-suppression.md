# Bug #36 — Silent Error Suppression in Step 5b

**Discovered:** 2026-07-27  
**Severity:** 🟠 HIGH  
**Location:** `setup-custodian-factory.sh`, line 255  
**Affected:** All deployments (masked Bug #34 for weeks)

## Symptoms

- Step 5b appears to succeed (`"Web search enabled"` message)
- But the DB was never actually updated (or was corrupted)
- No error visible to the user

## Root Cause

Line 255 uses a chain that destroys all error output:

```bash
" 2>/dev/null | grep -q 'OK'; then
```

- `2>/dev/null` — discards ALL stderr (Python tracebacks, SQL errors, import errors)
- `grep -q 'OK'` — only passes if "OK" appears in stdout
- If the Python script crashes before printing "OK", the `if` silently takes the `else` branch
- The `else` branch prints a mild warning: "WebUI may need to restart before toggle appears"
- This warning looks like a timing issue — user waits, refreshes, nothing changes

### What this masked

When `sqlite3` binary wasn't found in the container (Bug #34 context), the script could have been using Python's `sqlite3` module, but any error (wrong path, permission denied, corrupt DB) was completely invisible.

## Fix

Replace the `2>/dev/null` pipeline with proper error handling:

```bash
STEP5B_OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')
...
print('OK')
" 2>&1)

if echo "$STEP5B_OUTPUT" | grep -q 'OK'; then
  log_ok "Web search enabled — SearXNG: http://searxng:8080"
else
  log_error "Web search config FAILED"
  log_error "Output: $STEP5B_OUTPUT"
fi
```

This way, if the Python script crashes, the full error is shown to the user.

## Prevention Rule

**Never use `2>/dev/null` in diagnostic/verification code.** If a step can fail, the error must be visible. Use `2>&1` and capture the output for logging.

## Related

- Bug #34 (JSON column corruption) — the actual error this suppressed
- Bug #8 in deploy catalog (`|| true` anti-pattern) — same class: swallowing errors to avoid script termination
