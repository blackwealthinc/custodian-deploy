#!/bin/bash
# Custodian — PullMD Web Extraction Engine Setup
# Run ONCE per physical server. All Hermes instances share this.
# Connects via MCP at http://pullmd:3000/mcp (Docker DNS).
#
# One-liner:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-extractor.sh | sudo -E bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}OK:${NC} $1"; }
log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}WARN:${NC} $1"; }
log_info()  { echo -e "  -> $1"; }

[ "$(id -u)" -ne 0 ] && { log_error "Must run as root"; exit 1; }

COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.pullmd.yml"
COMPOSE_FILE="docker-compose.pullmd.yml"
PULLMD_DIR="/opt/pullmd"

log_step 'Step 1: System Update'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl
log_ok 'System updated'

log_step 'Step 2: Docker'
if ! command -v docker &>/dev/null; then
    log_info 'Installing Docker Engine...'
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    log_info "Docker already installed: $(docker --version)"
fi
log_ok 'Docker ready'

log_step 'Step 3: Create PullMD Directory'
mkdir -p "$PULLMD_DIR/data"
cd "$PULLMD_DIR"
log_ok "Directory: $PULLMD_DIR"

log_step 'Step 4: Download Compose File'
curl -sS -o "$COMPOSE_FILE" "$COMPOSE_URL"
log_ok 'Compose file downloaded'

log_step 'Step 5: Start PullMD'
docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
if ! docker compose -f "$COMPOSE_FILE" up -d; then
  log_error "docker compose up -d failed — check logs: docker compose -f $COMPOSE_FILE logs"
  exit 1
fi

# Wait for PullMD health check to pass
log_info "Waiting for PullMD to be healthy..."
HEALTH=""
for i in $(seq 1 30); do
  HEALTH=$(docker inspect pullmd --format '{{.State.Health.Status}}' 2>/dev/null) || true
  [ "$HEALTH" = "healthy" ] && break
  sleep 2
done
if [ "$HEALTH" != "healthy" ]; then
  log_error "PullMD health check failed — check: docker logs pullmd"
  exit 1
fi
log_ok 'PullMD healthy'

# Also verify trafilatura sidecar
if docker exec pullmd-trafilatura python -c "import urllib.request; urllib.request.urlopen('http://localhost:8001/health')" 2>/dev/null; then
  log_ok 'Trafilatura sidecar healthy'
else
  log_warn 'Trafilatura sidecar health check failed — check: docker logs pullmd-trafilatura'
fi

log_step 'Step 6: Verify Extraction'
# Test with a simple, reliable page
EXTRACT_RESULT=$(curl -s "http://localhost:3001/api?url=https://example.com" 2>/dev/null) || true
if echo "$EXTRACT_RESULT" | grep -q 'Example Domain'; then
  log_ok "PullMD verified — extraction working"
else
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001/api?url=https://example.com 2>/dev/null || echo 000)
  log_error "PullMD extraction failed (HTTP $HTTP_CODE)"
  log_error "Check: docker logs pullmd"
  exit 1
fi

echo ''
echo '=== PULLMD — READY ==='
echo "  MCP Endpoint:  http://pullmd:3000/mcp    (for Hermes on extractor-net)"
echo "  Local API:     http://127.0.0.1:3001/api  (diagnostics only)"
echo "  Config:        $PULLMD_DIR"
echo "  Logs:          docker logs pullmd"
echo ''
echo '  The factory compose auto-attaches Hermes to extractor-net (Bug #113).'
echo '  Just set the MCP config once per Hermes instance:'
echo '    docker exec <customer>-hermes hermes config set mcp_servers.pullmd.url http://pullmd:3000/mcp'
echo '    docker restart <customer>-hermes'
