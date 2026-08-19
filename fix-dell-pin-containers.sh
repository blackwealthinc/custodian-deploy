#!/bin/bash
# ============================================================================
# Custodian — Fix: Pin auxiliary container images on Dell (Bug #111)
# ============================================================================
# Pins searxng, pullmd, and pullmd-trafilatura from :latest to their exact
# running digests (supply-chain hardening), then recreates those containers.
# ONLY changes image tags — ports, volumes, networks, and env are untouched.
#
# The pinned digests are byte-identical to the images already running, so this
# is a LABEL change (latest -> @sha256:...), NOT an upgrade or downgrade.
#
# Idempotent: safe to re-run. Re-running when already pinned is a no-op.
# ============================================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log_step() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_ok()   { echo -e "  ${GREEN}OK:${NC} $1"; }
log_err()  { echo -e "  ${RED}ERROR:${NC} $1"; }

# Pinned digests = the images currently running (verified 2026-08-19).
SEARXNG_DIGEST="sha256:d0aaeb14880e6e92bde1518fcc7261e995783367d63d95203383607bef9c6516"
PULLMD_DIGEST="sha256:d8e7dfab3c62e8b7283c98aefe7091311c9cf323314f499ec3fa182eec7d3292"
TRAFILATURA_DIGEST="sha256:a68585d8ae41fd6f4673c39d4c9f3b58c04160ab4de8babb7c97b5f6e8c7b17e"

# ── 1. Pin SearXNG compose (searxng only — valkey is already versioned) ──
log_step "Pin SearXNG image"
SEARXNG_FILE="/opt/searxng/docker-compose.searxng.yml"
if [ ! -f "$SEARXNG_FILE" ]; then
    log_err "$SEARXNG_FILE not found"
    exit 1
fi
sed -i "s|image: searxng/searxng:latest|image: searxng/searxng@${SEARXNG_DIGEST}|" "$SEARXNG_FILE"
grep -q "searxng/searxng@sha256:" "$SEARXNG_FILE" && log_ok "searxng compose pinned" || { log_err "searxng pin failed"; exit 1; }

# ── 2. Pin PullMD + Trafilatura compose ──
log_step "Pin PullMD + Trafilatura images"
PULLMD_FILE="/opt/pullmd/docker-compose.pullmd.yml"
if [ ! -f "$PULLMD_FILE" ]; then
    log_err "$PULLMD_FILE not found"
    exit 1
fi
sed -i "s|image: aeternalabshq/pullmd-trafilatura:latest|image: aeternalabshq/pullmd-trafilatura@${TRAFILATURA_DIGEST}|" "$PULLMD_FILE"
sed -i "s|image: aeternalabshq/pullmd:latest|image: aeternalabshq/pullmd@${PULLMD_DIGEST}|" "$PULLMD_FILE"
grep -q "pullmd@sha256:" "$PULLMD_FILE" && grep -q "pullmd-trafilatura@sha256:" "$PULLMD_FILE" && log_ok "pullmd compose pinned" || { log_err "pullmd pin failed"; exit 1; }

# ── 3. Recreate the containers with the pinned images ──
log_step "Recreate containers (pinned images)"
cd /opt/searxng
docker compose -f docker-compose.searxng.yml up -d --force-recreate --no-deps searxng
cd /opt/pullmd
docker compose -f docker-compose.pullmd.yml up -d --force-recreate pullmd pullmd-trafilatura

# ── 4. Verify each container now carries the pinned digest ──
log_step "Verify"
sleep 12
for c in searxng pullmd pullmd-trafilatura; do
    IMG=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null || echo "MISSING")
    if echo "$IMG" | grep -q "@sha256:"; then
        log_ok "$c -> $IMG"
    else
        log_err "$c still shows: $IMG"
    fi
done

echo ""
docker ps --format '{{.Names}} | {{.Status}} | {{.Image}}' | grep -iE 'searxng|pullmd'

echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  DONE — auxiliary containers pinned to digests${NC}"
echo -e "${GREEN}=============================================${NC}"
