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
log_info()  { echo -e "  -> $1"; }

[ "$(id -u)" -ne 0 ] && { log_error "Must run as root"; exit 1; }

# Required: CUSTOMER_API_KEY
if [ -z "${CUSTOMER_API_KEY:-}" ]; then
  echo "ERROR: CUSTOMER_API_KEY is required"
  exit 1
fi

# Configuration
CUSTOMER_API_KEY="${CUSTOMER_API_KEY}"
BUDGET_PROXY_URL="${BUDGET_PROXY_URL:-https://budget.ns1net.com/v1}"
PORT="${PORT:-8642}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
CUSTOMER_ID="${CUSTOMER_ID:-custodian}"
[ -z "${API_SERVER_KEY:-}" ] && export API_SERVER_KEY=$(openssl rand -hex 32)
[ -z "${WEBUI_SECRET_KEY:-}" ] && export WEBUI_SECRET_KEY=$(openssl rand -hex 32)

SERVER_IP=$(hostname -I | awk '{print $1}')
COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.custodian-factory.yml"

log_step 'Step 0: Timezone'
timedatectl set-timezone America/Chicago 2>/dev/null || true
log_ok 'Timezone set'

log_step 'Step 1: System Update'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl
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
[ "${SKIP_HERMES:-0}" != "1" ] && docker pull nousresearch/hermes-agent:latest
log_ok 'Hermes image ready'

log_step 'Step 4: Deploy Stack'
[ ! -f docker-compose.custodian-factory.yml ] && curl -sS -o docker-compose.custodian-factory.yml "$COMPOSE_URL"

  BUDGET_PROXY_URL="${BUDGET_PROXY_URL}" \
  API_SERVER_KEY="${API_SERVER_KEY}" \
  PORT=$PORT WEBUI_PORT=$WEBUI_PORT CUSTOMER_ID=$CUSTOMER_ID \
  docker compose -p $CUSTOMER_ID -f docker-compose.custodian-factory.yml up -d

# Save .env
cat > .env.custodian-factory << EOF
API_SERVER_KEY=${API_SERVER_KEY}
WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
CUSTOMER_API_KEY=${CUSTOMER_API_KEY}
BUDGET_PROXY_URL=${BUDGET_PROXY_URL}
EOF
chmod 600 .env.custodian-factory
log_ok 'Keys saved'

log_step 'Step 5: Configure Hermes Routing'
sleep 15
HERMES_CONTAINER="$CUSTOMER_ID-hermes"
# Use openai provider to avoid DeepSeek 401 bug
docker exec $HERMES_CONTAINER hermes config set model.provider openai 2>/dev/null || true
docker exec $HERMES_CONTAINER hermes config set model.base_url "${BUDGET_PROXY_URL}" 2>/dev/null || true
docker exec $HERMES_CONTAINER hermes config set model.default hermes-agent 2>/dev/null || true
docker exec $HERMES_CONTAINER hermes config unset model.api_key 2>/dev/null || true
log_ok "Hermes routing: openai -> ${BUDGET_PROXY_URL}"

log_step 'Step 6: Verify'
sleep 10
HERMES_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PORT:-8642}/v1/health 2>/dev/null || echo 000)
OWUI_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${WEBUI_PORT:-3000} 2>/dev/null || echo 000)
echo "  Hermes: HTTP $HERMES_CODE | Open WebUI: HTTP $OWUI_CODE"

echo ''
echo '=== CUSTODIAN — READY ==='
echo "  Open WebUI:  http://${SERVER_IP}:${WEBUI_PORT:-3000}"
echo "  Hermes API:  http://${SERVER_IP}:${PORT:-8642}/v1"
echo "  Budget Proxy: ${BUDGET_PROXY_URL}"