#!/bin/bash
# Custodian Customer Server Setup
# Routes ALL AI requests through Budget Proxy (LiteLLM)
#
# One-liner:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | sudo bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}OK:${NC} $1"; }
log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}WARN:${NC} $1"; }
log_info()  { echo -e "  -> $1"; }

[ "$(id -u)" -ne 0 ] && { log_error "Must run as root"; exit 1; }

# Ensure we have a real working directory (survives wipes)
WORKDIR="${CUSTODIAN_HOME:-/home/custodian}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
log_ok "Working directory: $(pwd)"

# Auto-generate virtual key if not provided (requires LITELLM_MASTER_KEY)
if [ -z "${CUSTOMER_API_KEY:-}" ]; then
  if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
    echo "ERROR: CUSTOMER_API_KEY or LITELLM_MASTER_KEY is required"
    echo "  Provide CUSTOMER_API_KEY directly, or set LITELLM_MASTER_KEY for auto-generation"
    exit 1
  fi
  log_info "Auto-generating virtual key via Budget Proxy..."
  KEY_RESPONSE=$(curl -s -X POST "${BUDGET_PROXY_URL%/v1}/key/generate" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"key_alias\": \"${CUSTOMER_ID:-custodian}\", \"models\": [\"deepseek-v4-pro\"], \"max_budget\": ${MAX_BUDGET:-25}, \"budget_duration\": \"1mo\"}" 2>/dev/null)
  CUSTOMER_API_KEY=$(echo "$KEY_RESPONSE" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "${CUSTOMER_API_KEY}" ]; then
    echo "ERROR: Failed to auto-generate API key. Response:"
    echo "$KEY_RESPONSE" | head -5
    exit 1
  fi
  export CUSTOMER_API_KEY="${CUSTOMER_API_KEY}"
  log_ok "Virtual key generated: ${CUSTOMER_API_KEY:0:16}..."
fi

# Configuration
CUSTOMER_API_KEY="${CUSTOMER_API_KEY}"
BUDGET_PROXY_URL="${BUDGET_PROXY_URL:-https://budget.ns1net.com/v1}"
PORT="${PORT:-8642}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
CUSTOMER_ID="${CUSTOMER_ID:-custodian}"
MAX_BUDGET="${MAX_BUDGET:-25}"

# Reuse existing API_SERVER_KEY from WebUI database on re-runs (Bug #18 fix)
# Without this, every re-run generates a new random key → Hermes gets new key
# but WebUI database still has old key → "No models available"
if [ -z "${API_SERVER_KEY:-}" ] && [ -f "webui-data/webui.db" ]; then
  EXISTING_KEY=$(python3 -c "
import sqlite3, json
conn = sqlite3.connect('webui-data/webui.db')
row = conn.execute(\"SELECT value FROM config WHERE key='openai.api_keys'\").fetchone()
if row:
    keys = json.loads(row[0])
    print(keys[0] if keys else '')
" 2>/dev/null)
  if [ -n "${EXISTING_KEY}" ]; then
    export API_SERVER_KEY="${EXISTING_KEY}"
    log_ok "Reusing existing API_SERVER_KEY from WebUI database"
  fi
fi
[ -z "${API_SERVER_KEY:-}" ] && export API_SERVER_KEY=$(openssl rand -hex 32)
[ -z "${WEBUI_SECRET_KEY:-}" ] && export WEBUI_SECRET_KEY=$(openssl rand -hex 32)

# Hermes version pin -- update when upgrading
# Find current: docker run --rm nousresearch/hermes-agent:latest hermes --version
HERMES_PINNED_VERSION="v2026.7.20"
HERMES_PINNED_DIGEST="sha256:0e06e95613c7536e14f33e9dd5f7c15db676fc25c6c13e350c69ce47e1464033"

SERVER_IP=$(hostname -I | awk '{print $1}')
COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/71f412a/docker-compose.custodian-factory.yml"

log_step 'Step 0: Timezone'
timedatectl set-timezone America/Chicago 2>/dev/null || true
log_ok 'Timezone set'

log_step 'Step 1: System Update'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl python3
log_ok 'System updated'

log_step 'Step 2: Docker'

# ── Auto-detect Proxmox LXC ──
# docker-ce pulls containerd 1.7.x which triggers
# "ip_unprivileged_port_start: permission denied" inside LXC.
# docker.io ships containerd 1.6.x which works in LXC.
# See: research/proxmox-lxc-containerd-fix-plan.md
IS_LXC=false
if [ -f /run/systemd/container ]; then
    CT_TYPE=$(cat /run/systemd/container 2>/dev/null || echo "")
    [ "$CT_TYPE" = "lxc" ] || [ "$CT_TYPE" = "lxc-libvirt" ] && IS_LXC=true
fi
grep -qa 'lxc' /proc/1/environ 2>/dev/null && IS_LXC=true
[ -d /dev/lxd ] || [ -d /var/lib/lxc ] && IS_LXC=true

# Install or fix Docker (LXC-aware with containerd version check)
if command -v docker &>/dev/null; then
    if [ "$IS_LXC" = true ]; then
        CONTAINERD_VER=$(containerd --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
        if dpkg --compare-versions "$CONTAINERD_VER" ge "1.7.28" 2>/dev/null; then
            log_warn "containerd $CONTAINERD_VER on LXC is broken — switching to docker.io..."
            apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            apt-get update -qq
            apt-get install -y -qq docker.io docker-compose-v2
            systemctl restart docker
        else
            log_info "Docker already installed (containerd $CONTAINERD_VER, LXC-compatible)"
        fi
    else
        log_info "Docker already installed: $(docker --version)"
    fi
else
    if [ "$IS_LXC" = true ]; then
        log_warn "Proxmox LXC detected — using docker.io (containerd 1.6.x, LXC-safe)"
        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-v2
    else
        log_info "Installing Docker Engine (official repo)..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable --now docker
fi
log_ok "Docker: $(docker --version)"

log_step 'Step 3: Pull Hermes'
HERMES_IMAGE="nousresearch/hermes-agent:${HERMES_PINNED_VERSION}"
if [ "${SKIP_HERMES:-0}" != "1" ]; then
  docker pull "$HERMES_IMAGE"
  ACTUAL_VERSION=$(docker run --rm "$HERMES_IMAGE" hermes --version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "unknown")
  if [ "$ACTUAL_VERSION" != "${HERMES_PINNED_VERSION}" ] && [ "$ACTUAL_VERSION" != "unknown" ]; then
    echo ""
    echo "  =============================================="
    echo "  ${YELLOW}WARNING: HERMES VERSION MISMATCH${NC}"
    echo "  Expected: ${HERMES_PINNED_VERSION}"
    echo "  Got:      $ACTUAL_VERSION"
    echo "  The image tag has been updated."
    echo "  Update HERMES_PINNED_VERSION in setup-custodian-factory.sh"
    echo "  and docker-compose.custodian-factory.yml"
    echo "  =============================================="
    echo ""
  fi
fi
log_ok "Hermes image ready (pinned: ${HERMES_PINNED_VERSION})" 

log_step 'Step 4: Deploy Stack'
# Always download latest compose file — fixes are pushed to GitHub regularly (Bug #18 fix)
curl -sS -o docker-compose.custodian-factory.yml "$COMPOSE_URL"

  BUDGET_PROXY_URL="${BUDGET_PROXY_URL}" \
  API_SERVER_KEY="${API_SERVER_KEY}" \
  PORT=$PORT WEBUI_PORT=$WEBUI_PORT CUSTOMER_ID=$CUSTOMER_ID \
  docker compose -p $CUSTOMER_ID -f docker-compose.custodian-factory.yml up -d

# Save .env (namespaced by CUSTOMER_ID — prevents overwrite when adding more customers)
cat > .env.${CUSTOMER_ID}-factory << EOF
API_SERVER_KEY=${API_SERVER_KEY}
WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
CUSTOMER_API_KEY=${CUSTOMER_API_KEY}
BUDGET_PROXY_URL=${BUDGET_PROXY_URL}
EOF
chmod 600 .env.${CUSTOMER_ID}-factory
log_ok 'Keys saved'

log_step 'Step 5: Configure Hermes Routing'
sleep 15
HERMES_CONTAINER="$CUSTOMER_ID-hermes"

# Helper: run hermes config, capture errors — never use || true (Bug #8 in deploy catalog)
hermes_set() {
  local key="$1" val="$2" fatal="${3:-false}"
  local err
  err=$(docker exec "$HERMES_CONTAINER" hermes config set "$key" "$val" 2>&1) || {
    if [ "$fatal" = "true" ]; then
      log_error "Hermes config FATAL — $key: $err"
      exit 1
    else
      log_warn "Hermes config — $key: $err"
    fi
    return 1
  }
  return 0
}

# Core routing (fatal — AI won't work without these)
hermes_set model.provider custom true
hermes_set model.base_url "${BUDGET_PROXY_URL}" true
hermes_set model.default deepseek-v4-pro true
hermes_set model.api_key "${CUSTOMER_API_KEY}" true

# Display (non-fatal)
hermes_set platforms.api_server.extra.model_name "Custodian AI"

# SearXNG connectivity check — uses DNS, not dead config keys
# The SEARXNG_URL env var (in compose) is what Hermes actually reads
if docker exec "$HERMES_CONTAINER" getent hosts searxng >/dev/null 2>&1; then
  # Verify SearXNG actually responds
  if docker exec "$HERMES_CONTAINER" curl -s --connect-timeout 3 "http://searxng:8080/search?q=test&format=json" 2>/dev/null | grep -q '"results"'; then
    log_ok "SearXNG connected — web search active"
  else
    log_warn "SearXNG DNS resolves but search failed — check: docker logs searxng"
  fi
else
  log_warn "SearXNG NOT found — run setup-searxng.sh first on this server"
  log_warn "Web search will not work until SearXNG is deployed"
fi

# Ensure Hermes can reach SearXNG even on existing deployments (network may be missing)
docker network connect searxng-net "$HERMES_CONTAINER" 2>/dev/null || true

log_ok "Hermes routing: deepseek-v4-pro -> ${BUDGET_PROXY_URL} (display: Custodian AI)"

log_step 'Step 6: Verify'

# 1. Hermes health
HERMES_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PORT:-8642}/v1/health 2>/dev/null || echo 000)
if [ "$HERMES_CODE" = "200" ]; then
  log_ok "Hermes healthy (HTTP $HERMES_CODE)"
else
  log_error "Hermes: HTTP $HERMES_CODE — check: docker logs $HERMES_CONTAINER"
fi

# 2. WebUI — retry because first startup downloads models (Bug #21)
log_info "Waiting for WebUI to finish initializing (first start downloads models)..."
OWUI_CODE=000
for i in $(seq 1 60); do
  OWUI_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${WEBUI_PORT:-3000} 2>/dev/null || echo 000)
  [ "$OWUI_CODE" = "200" ] || [ "$OWUI_CODE" = "302" ] && break
  [ $((i % 6)) -eq 0 ] && log_info "  Still waiting... ($((i*10))s)"
  sleep 10
done
if [ "$OWUI_CODE" = "200" ] || [ "$OWUI_CODE" = "302" ]; then
  log_ok "WebUI ready (HTTP $OWUI_CODE)"
else
  log_warn "WebUI: HTTP $OWUI_CODE — may still be downloading models, refresh in 2-3 min"
fi

# 3. Budget Proxy — models listing
MODELS_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PORT:-8642}/v1/models 2>/dev/null || echo 000)
if [ "$MODELS_CODE" = "200" ]; then
  log_ok "Budget Proxy reachable — models listed"
else
  log_error "Budget Proxy: HTTP $MODELS_CODE — check Budget Proxy on VM205"
fi

# 4. SearXNG DNS
if docker exec "$HERMES_CONTAINER" getent hosts searxng >/dev/null 2>&1; then
  log_ok "SearXNG DNS resolves"
else
  log_warn "SearXNG DNS: FAIL — run setup-searxng.sh first"
fi

echo ''
echo '=== CUSTODIAN — READY ==='
echo "  Open WebUI:  http://${SERVER_IP}:${WEBUI_PORT:-3000}"
echo "  Hermes API:  http://${SERVER_IP}:${PORT:-8642}/v1"
echo "  Budget Proxy: ${BUDGET_PROXY_URL}"