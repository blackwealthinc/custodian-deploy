# Bug #50 — Open WebUI `:main` tag is unstable bleeding-edge

**Date:** 2026-07-29
**Found by:** Second-pass audit — Docker image inspection
**Severity:** Medium (risk of breaking changes on any redeploy)
**Status:** Logged

## Root Cause

The docker-compose uses `ghcr.io/open-webui/open-webui:main` which is the latest commit on the main branch. This means:
- Every `docker pull` gets a different version
- Filter function API may change without notice
- Model caching behavior may change
- Web search toggle visibility logic may change

The filter function we built was tested against whatever `:main` was on July 28-29, 2026. If `:main` updates tomorrow with breaking changes to the filter API, our filter silently breaks.

## Fix

Pin to a specific version tag instead of `:main`. Check what stable version tags are available (e.g., `v0.10.x`, `v0.9.x`) and use one. This ensures:
- Consistent behavior across all deployments
- Filter function API is stable
- Upgrades are intentional, not automatic

The Hermes image is already pinned (`v2026.7.20` with digest lock). The WebUI should follow the same pattern.

Reference: Docker best practices — always pin image tags in production.
