# Bug #35 — WebUI Not Connected to searxng-net

**Discovered:** 2026-07-27  
**Severity:** 🔴 CRITICAL  
**Location:** `docker-compose.custodian-factory.yml`, openwebui service (lines 53-75)  
**Affected:** Dell, all fresh deployments

## Symptoms

- Web search returns no results even though SearXNG is running
- `docker exec admin-webui getent hosts searxng` → `Name or service not known`
- `ENABLE_WEB_SEARCH=true` and `WEB_SEARCH_ENGINE=searxng` are set but web search doesn't work

## Root Cause

The `hermes` service explicitly connects to both networks:

```yaml
hermes:
  networks:
    - default
    - searxng-net      # ✅ Connected
```

The `openwebui` service has **NO `networks:` section**, so Docker Compose only connects it to `default`:

```yaml
openwebui:
  # NO networks: block   ❌ Only on default
```

Result:
```
admin-webui  → ONLY admin_default (172.19.0.3)
searxng      → ONLY searxng-net   (172.18.0.3)
                                       ↕ NO CONNECTION
```

Docker DNS cannot resolve container names across different networks.

## Fix

### Dell (immediate)

```bash
docker network connect searxng-net admin-webui
docker restart admin-webui
```

### Compose (permanent)

Add to the `openwebui` service in `docker-compose.custodian-factory.yml`:

```yaml
openwebui:
  ...
  networks:
    - default
    - searxng-net      # ← ADD THIS
```

### Script (safety net)

Add after line 226 in `setup-custodian-factory.sh`:

```bash
# Ensure WebUI can reach SearXNG even on existing deployments
docker network connect searxng-net "$WEBUI_CONTAINER" 2>/dev/null || true
```

## Related

- Bug #34 (JSON column corruption) — both prevent web search from working
- The Hermes safety net (line 226) exists but no equivalent for WebUI
