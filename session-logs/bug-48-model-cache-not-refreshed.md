# Bug #48 — WebUI model cache never refreshed after workspace model creation

**Date:** 2026-07-29
**Found by:** Second-pass audit — Dell container inspection
**Severity:** Critical (web search toggle invisible — core feature broken)
**Status:** Logged

## Root Cause

Open WebUI caches the model list at startup via `ENABLE_BASE_MODELS_CACHE` (default: enabled). The workspace model was created while the container was running, but the cache was never invalidated or refreshed.

**Evidence:**
- Container started: 09:48 CDT
- Model created: ~11:39 CDT (2 hours later)
- `/api/models` returns cached (empty) list — no workspace model found
- Web search toggle requires model with `web_search` capability in the model list

From Open WebUI source (`main.py:378`):
```python
if await Config.get('models.base_models_cache'):
    await get_all_models(request, ...)  # cached at startup
```

Reference: [Open WebUI env config docs](https://docs.openwebui.com/reference/env-configuration/) — `ENABLE_BASE_MODELS_CACHE` persists across restarts.

## Fix

Restart the WebUI container after Step 5d creates the workspace model. This forces Open WebUI to reload all models on next startup, picking up the new workspace entry with `web_search` capability.

```bash
docker restart "$WEBUI_CONTAINER"
```

This is safe because:
- Docker volumes preserve all data (webui.db, configs, chat history)
- Restart takes < 2 seconds
- No data loss — just a process restart
- Deterministic — model immediately available after restart
