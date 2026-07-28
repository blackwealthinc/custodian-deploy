# Bug #42 — Missing __init__ in Deep Research Action Function

**Date:** 2026-07-28
**Severity:** High
**Found By:** User (button not appearing) / WebDev (root cause)
**Status:** Fixed

## Summary

The Deep Research Action Function loads successfully (`Loaded module: function_566...`) but the button never appears in Open WebUI's message toolbar. Root cause: missing `__init__` method.

## Root Cause

Open WebUI's Action Function loader requires every Action class to have:

```python
def __init__(self):
    self.valves = self.Valves()
```

Without this, the class has no `valves` attribute. When Open WebUI instantiates the class and accesses `valves` (to check priority and valve settings), it fails silently. The function is in the database, registered in the API, but the button never renders.

## Evidence

- Function loaded: `Loaded module: function_566141a5-c9f2-4ae6-9576-7ea5990f665c`
- API endpoint returns 200: `GET /api/v1/functions/ HTTP/1.1 200`
- Database: `active=1, global=1, type=action` — all correct
- Source check: `Has __init__: False`

## Fix

Add between `class Valves` and `async def action`:

```python
    def __init__(self):
        self.valves = self.Valves()
```

## Affected

- `/setup-custodian-factory.sh` Step 5c (curl — same source code)
- Dell (manual injection — same source code)

## Reference

Open WebUI community example (GitHub Discussion #8274):
```python
class Action:
    class Valves(BaseModel):
        ...
    def __init__(self):
        self.valves = self.Valves()
    async def action(self, body, ...):
        ...
```
