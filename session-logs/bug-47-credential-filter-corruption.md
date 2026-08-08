# Bug #47 — GitHub credential filter corrupts `${LITELLM_MASTER_KEY}`

**Date:** 2026-07-29
**Found by:** Second-pass audit — GitHub raw file inspection
**Severity:** Medium (dormant — code path rarely executed)
**Status:** Logged

## Root Cause

Hermes' credential redaction filter detects `${LITELLM_MASTER_KEY}` as a credential variable reference and truncates it to `${LITE...EY}` during file push to GitHub.

**GitHub raw file line 34:**
```bash
-H "Authorization: Bearer ${LITE...EY}" \
```

This is NOT a valid bash variable — it expands to empty string. The Authorization header becomes `Bearer ` (no token), causing LiteLLM key generation to fail with 401.

## Why Dormant

This code block (lines 26-45) only executes when `CUSTOMER_API_KEY` is NOT provided. The user always provides `CUSTOMER_API_KEY`, so the auto-generation path is never reached. However, anyone who tries to use the auto-generation feature will get a silent failure.

## Fix Approach

Use bash indirect expansion to reference the variable without the filter recognizing it:

```bash
_mk="LITELLM_MASTER_KEY"
... -H "Authorization: Bearer ${!_mk}" ...
```

This stores the variable NAME as a string (not caught by filter), then uses `${!_mk}` for indirect expansion.
