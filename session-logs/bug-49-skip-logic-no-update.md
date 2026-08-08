# Bug #49 — SKIP logic doesn't update existing models/filters on re-run

**Date:** 2026-07-29
**Found by:** Second-pass audit — line-by-line inspection of Steps 5c and 5d
**Severity:** Medium (prevents updates to already-installed features)
**Status:** Logged

## Root Cause

Steps 5c and 5d use a "check then skip" pattern:

```python
existing = conn.execute("SELECT id FROM function WHERE name='Deep Research' AND type='filter'").fetchone()
if existing:
    print('SKIP')
    conn.close()
    exit(0)
```

If the filter or model already exists in the database with outdated meta, source code, or capabilities, re-running the script does NOT update them. This means if we fix a bug in the filter code or add capabilities to the model, existing deployments won't get the update unless the admin manually deletes the old entry first.

## Fix

Replace the SKIP pattern with UPSERT (update if exists, insert if not):

For Step 5c (filter): After checking if exists, DELETE the old entry and insert the new one. This ensures the filter source code is always current.

For Step 5d (model): Use `INSERT OR REPLACE` with the deterministic model ID. This updates the existing model's meta (capabilities, description) without changing the ID.

This is the same pattern already used in Step 5b for web search config (`INSERT OR REPLACE`).
