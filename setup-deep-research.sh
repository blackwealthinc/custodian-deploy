#!/bin/bash
# Custodian — Deep Research (GPT Researcher) Setup
# Run ONCE per physical server. Auto-connects to Budget Proxy + SearXNG.
#
# One-liner:
#   CUSTOMER_API_KEY=*** \
#     BUDGET_PROXY_URL=http://100.64.0.1:4000/v1 \
#     curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-deep-research.sh | sudo -E bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}OK:${NC} $1"; }
log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}WARN:${NC} $1"; }
log_info()  { echo -e "  -> $1"; }

[ "$(id -u)" -ne 0 ] && { log_error "Must run as root"; exit 1; }

# Required: CUSTOMER_API_KEY
if [ -z "${CUSTOMER_API_KEY:-}" ]; then
  echo "ERROR: CUSTOMER_API_KEY is required (your LiteLLM virtual key from Budget Proxy)"
  echo "Usage: export CUSTOMER_API_KEY=*** && curl ... | sudo -E bash"
  exit 1
fi

# Configuration
CUSTOMER_API_KEY="${CUSTOMER_API_KEY}"
BUDGET_PROXY_URL="${BUDGET_PROXY_URL:-http://100.64.0.1:4000/v1}"
SEARX_URL="${SEARX_URL:-http://searxng:8080}"
GPTR_DIR="/opt/gpt-researcher"
COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.gpt-researcher.yml"

log_step 'Step 1: System Update'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl
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

log_step 'Step 3: Create GPT Researcher Directory'
mkdir -p "$GPTR_DIR"/{gptr-docs,gptr-outputs,gptr-logs}
cd "$GPTR_DIR"
log_ok "Directory: $GPTR_DIR"

log_step 'Step 4: Download Compose File'
curl -sS -o docker-compose.gpt-researcher.yml "$COMPOSE_URL"
log_ok 'Compose file downloaded'

log_step 'Step 5: Deploy GPT Researcher'
# Ensure it can reach SearXNG on the shared network
docker network create searxng-net 2>/dev/null || true

# Pass env vars through to compose
export CUSTOMER_API_KEY BUDGET_PROXY_URL SEARX_URL

docker compose -f docker-compose.gpt-researcher.yml down --remove-orphans 2>/dev/null || true
docker compose -f docker-compose.gpt-researcher.yml up -d
log_ok 'GPT Researcher containers started'

log_step 'Step 6: Verify'
sleep 30
GPTR_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/health 2>/dev/null || echo 000)
if [ "$GPTR_CODE" = "200" ]; then
    log_ok "GPT Researcher API responding: HTTP 200"
else
    log_warn "GPT Researcher returned HTTP $GPTR_CODE (may still be initializing)"
    log_info "Check: docker logs gpt-researcher"
fi

echo ''
echo '=== DEEP RESEARCH — READY ==='
echo "  API:      http://localhost:8000"
echo "  LLM:      ${BUDGET_PROXY_URL} (via Budget Proxy)"
echo "  Search:   ${SEARX_URL} (via SearXNG)"
echo "  Reports:  $GPTR_DIR/gptr-outputs/"
echo ''
echo '  Test it:'
echo '    curl -X POST http://localhost:8000/research \'
echo '      -H "Content-Type: application/json" \'
echo '      -d '"'"'{"query": "What is the future of AI agents in 2026?"}'"'"''
echo ''
echo '  Connect Open WebUI as an external tool:'
echo '    Settings > Connections > OpenAI API'
echo '    URL: http://localhost:8000/v1'
echo '    Or add as a Workspace Function for a "Deep Research" button.'
