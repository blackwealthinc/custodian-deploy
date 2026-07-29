# Bug #46 — Empty model table: web search toggle invisible

**Date:** 2026-07-29
**Found by:** Dell audit after Deep Research filter installation
**Severity:** Critical (core feature not visible to users)
**Status:** Fixed

## Root Cause

The `model` table in Open WebUI's `webui.db` is empty (0 rows). Open WebUI only shows the web search toggle (globe icon) for models that have `web_search` in their capabilities metadata. API-fetched models like "Custodian" (from Hermes) have no workspace model entry, so Open WebUI doesn't know they support web search.

## Evidence

```
=== MODEL TABLE ===
Model count: 0
```

Web search config IS correct in the `config` table:
- `web.search.enable = true`
- `web.search.engine = "searxng"`
- `web.search.searxng_query_url = "http://searxng:8080/search?q=<query>"`

But without a model with capabilities, the toggle stays hidden.

## Open WebUI Model Schema

From [database-schema.md](https://github.com/open-webui/docs/blob/main/docs/reference/database-schema.md):

| Column | Type | Description |
|---|---|---|
| id | Text (PK) | UUID |
| user_id | Text | Model owner (NULL for system) |
| base_model_id | Text | Parent model reference |
| name | Text | Display name |
| params | JSON | Model parameters |
| meta | JSON | Model metadata (capabilities, filterIds, etc.) |
| is_active | Boolean | default=True |

The `meta` JSON stores capabilities:
```json
{
  "capabilities": {
    "web_search": true
  }
}
```

## Fix

Create a workspace model entry in Step 5d:
- name: "Custodian"
- base_model_id: "Custodian" (matches Hermes `/v1/models` response)
- user_id: NULL (system model, available to all users)
- meta: `{"capabilities": {"web_search": true}}`
- is_active: True
- Idempotent: checks for existing model before inserting

## Also Fixes

- Bug #47: Filter attachment — global filter automatically attaches when model capabilities include web_search
- `web.search.concurrent_requests = NULL` → fixed to `0` in Step 5b
