# Bug #51 — Deep Research filter loaded but never triggered

**Date:** 2026-07-29
**Found by:** Second-pass audit — WebUI log inspection
**Severity:** High (core feature may be completely non-functional)
**Status:** Logged — needs user verification

## Root Cause

The filter function IS loaded by Open WebUI at startup:
```
Loaded module: function_fcc0a004-1882-48ba-9e60-93afbf52b209
```

However, there are ZERO filter `inlet` invocations in the WebUI logs. The filter is loaded into memory but there's no evidence it ever runs when a chat message is sent.

Possible causes:
1. No chat messages have been sent since the filter was installed (the user hasn't tested `/research` yet)
2. The filter is loaded but Open WebUI's filter dispatch system doesn't recognize it as active
3. The `AssertionError` and `RuntimeError` in the logs indicate broader middleware issues that may prevent filter execution
4. The filter's `is_global=True` may not be sufficient on the current `:main` version

## Investigation Needed

The user should test by typing `/research test` in a chat. If the filter triggers:
- The message "/research test" should be replaced with just "test" as the user message
- A status message "Deep Research: searching 10+ sources..." should appear
- The system should receive the deep research prompt

If nothing happens, the filter registration mechanism on this Open WebUI version needs further investigation.

## Fix

After Bug #48 is fixed (restart WebUI), the filter should be reloaded. The user tests `/research`. If still no trigger:
- Check Open WebUI's function management UI (Admin → Functions)
- Verify filter shows as "Active" and "Global"
- Check if the model has the filter in its filterIds
- Consider adding `self.toggle = True` to make the filter user-visible/toggleable as a fallback
