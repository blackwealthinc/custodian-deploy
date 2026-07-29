# Bug #45 — Deep Research filter: `/research` prefix is case-sensitive

**Date:** 2026-07-29
**Found by:** Line-by-line curl audit (Deep Research filter audit)
**Severity:** Low (workaround exists — user can lowercase, but confusing UX)
**Status:** Fixed

## Root Cause

The Deep Research filter on line 337 checked for `/research` with exact case:

```python
if not content.strip().startswith("/research"):
    return body
```

Users naturally type `/Research`, `/RESEARCH`, or `/DeepResearch` with capital letters. None of these would trigger the filter, silently passing the message through unchanged.

## Fix

Lowercase before comparison:

```python
if not content.strip().lower().startswith("/research"):
    return body
```

The question extraction on the next line (`content.strip()[len("/research"):].strip()`) uses the ORIGINAL content, preserving the user's case for the actual question. Only the prefix check is lowercased.

## Verification

- `/research what is X` → triggers, question: "what is X"
- `/Research what is X` → triggers, question: "What is X" (original case preserved)
- `/RESEARCH what is X` → triggers, question: "WHAT IS X" (original case preserved)
- `what is /research` → does NOT trigger (doesn't START with /research)
