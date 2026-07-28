# Bug #38 — Factory Script Missing extractor-net Wiring

**Date:** 2026-07-28
**Severity:** High
**Found By:** WebDev (self-audit)
**Status:** Fixed

## Summary

The `setup-custodian-factory.sh` script connects Hermes to `searxng-net` for web search but never connects Hermes to `extractor-net` for PullMD web extraction. After running `setup-extractor.sh`, the user must manually run:

```bash
docker network connect extractor-net admin-hermes
docker exec admin-hermes hermes config set mcp_servers.pullmd.url http://pullmd:3000/mcp
```

On fresh deployments, the extraction tool never appears in Hermes unless manually wired.

## Root Cause

When `setup-extractor.sh` was created (commit 7fdb24f), the factory script was not updated to add the corresponding wiring. The factory only has:

```bash
docker network connect searxng-net "$HERMES_CONTAINER" 2>/dev/null || true  # line 226
docker network connect searxng-net "$WEBUI_CONTAINER" 2>/dev/null || true   # line 236
```

No equivalent for `extractor-net`.

## Fix

Added extractor-net wiring block after the SearXNG Hermes connection:

```bash
# Wire Hermes to extractor-net for PullMD web extraction
if docker network inspect extractor-net >/dev/null 2>&1; then
    docker network connect extractor-net "$HERMES_CONTAINER" 2>/dev/null || true
    docker exec "$HERMES_CONTAINER" hermes config set mcp_servers.pullmd.url http://pullmd:3000/mcp 2>/dev/null || \
        log_warn "Could not configure PullMD MCP in Hermes (non-fatal)"
    log_ok "PullMD extraction wired to Hermes"
else
    log_warn "extractor-net not found — web extraction unavailable. Run setup-extractor.sh first."
fi
```

## Verification

- extractor-net is optional — if missing, the script warns but continues
- If present, Hermes is connected and MCP config is set
- `|| true` on network connect handles "already connected" errors
- MCP config failure is non-fatal (Hermes may need restart for MCP to pick up)
