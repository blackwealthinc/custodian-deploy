# Bug #37 — Usage Example Shows `| sudo bash` (Env Vars Stripped)

**Discovered:** 2026-07-27  
**Severity:** 🟡 MEDIUM  
**Location:** `setup-custodian-factory.sh`, line 6  
**Affected:** All users following the inline-var usage pattern

## Symptoms

User runs:
```bash
DEEPSEEK_API_KEY=*** CUSTOMER_API_KEY=*** \
  curl -s .../setup-custodian-factory.sh | sudo bash
```

Result: `ERROR: CUSTOMER_API_KEY is required but not set`

## Root Cause

`sudo` strips environment variables by default (security feature). The inline `VAR=val` assignment only applies to the `curl` command, not to the `sudo bash` process that follows the pipe.

## Fix

Line 6 currently shows:
```bash
#   curl -s https://.../setup-custodian-factory.sh | sudo bash
```

Should show:
```bash
#   export VAR=val && curl -s https://.../setup-custodian-factory.sh | sudo -E bash
```

Also update `all-curl-commands-reference.md` with the `export` + `sudo -E` pattern.

## Related

- Bug #1 from custodian-deploy testing: same root cause discovered during CT 204/CT 205 testing
- `all-curl-commands-reference.md` in research/ folder
