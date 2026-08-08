#!/bin/bash
# ============================================================================
# Custodian — Budget Proxy Setup (LiteLLM)
# ============================================================================
# What this does:
#   Deploys LiteLLM (AI Gateway) via Docker as the central Budget Proxy.
#   Routes all customer AI requests through DeepSeek with per-customer
#   virtual keys, token counting, and budget enforcement.
#
# Prerequisites:
#   - Ubuntu 22.04 LTS or 24.04 LTS
#   - setup-database.sh must have been run FIRST (PostgreSQL on localhost)
#   - Root access, internet access
#
# Environment variables:
#   DEEPSEEK_API_KEY      — DeepSeek API key (REQUIRED)
#   BUDGET_PROXY_DOMAIN   — Domain for proxy (default: budget.ns1net.com)
#   LITELLM_PORT          — Proxy port (default: 443)
#   DB_PASSWORD           — PostgreSQL password (reads from .db-credentials if not set)
#
# One-liner:
#   export DEEPSEEK_API_KEY=*** \
#   export BUDGET_PROXY_DOMAIN=*** && \
#     curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-budget-proxy.sh | sudo -E bash
#
# Architecture: custodian-architecture-budget-proxy-scaling.md § 2-3
# Operations:   custodian-operations-guide.md § 1-2
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}OK:${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}WARN:${NC} $1"; }
log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }
log_info()  { echo -e "  -> $1"; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "Must run as root"
    exit 1
fi

# ── Validate Required Input ──
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
    log_error "DEEPSEEK_API_KEY is required but not set"
    echo "  Usage: export DEEPSEEK_API_KEY=*** && ... | sudo -E bash"
    exit 1
fi

if [ -z "${DASHSCOPE_API_KEY:-}" ]; then
    log_error "DASHSCOPE_API_KEY is required but not set"
    echo "  Usage: export DASHSCOPE_API_KEY=*** && ... | sudo -E bash"
    exit 1
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
    log_error "OPENAI_API_KEY is required but not set"
    echo "  Usage: export OPENAI_API_KEY=*** && ... | sudo -E bash"
    exit 1
fi

BUDGET_PROXY_DOMAIN="${BUDGET_PROXY_DOMAIN:-budget.ns1net.com}"
LITELLM_PORT="${LITELLM_PORT:-443}"
LITELLM_MASTER_KEY="sk-$(openssl rand -hex 32)"
LITELLM_SALT_KEY=$(openssl rand -hex 32)
_LMK_VN="LITELLM_MASTER""_KEY"  # indirection pattern (Bug #52 fix, DANGER ZONE #11)
_DSK_VN="DASHSCOPE_""_API_KEY"  # indirection pattern (DANGER ZONE #11)
_OAI_VN="OPENAI_""_API_KEY"     # indirection pattern — image generation
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@custodian.app}"

# ── Database credentials ──
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-custodian}"
DB_USER="${DB_USER:-custodian}"

if [ -z "${DB_PASSWORD:-}" ]; then
    if [ -f /opt/custodian-db/.db-credentials ]; then
        DB_PASSWORD=$(grep '^DB_PASSWORD=' /opt/custodian-db/.db-credentials | cut -d= -f2)
    fi
    if [ -z "${DB_PASSWORD:-}" ]; then
        log_error "DB_PASSWORD not set and .db-credentials not found"
        log_error "Run setup-database.sh first, or set DB_PASSWORD env var"
        exit 1
    fi
fi

SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}"
echo "  Custodian — Budget Proxy Setup (LiteLLM)"
echo "  Domain: ${BUDGET_PROXY_DOMAIN} | Port: ${LITELLM_PORT}"
echo -e "${NC}"

# ============================================================
# STEP 1: System Update & Docker
# ============================================================
log_step "Step 1: System Update & Docker"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl

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
    # Docker already installed — check if it's LXC-compatible
    if [ "$IS_LXC" = true ]; then
        CONTAINERD_VER=$(containerd --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
        if dpkg --compare-versions "$CONTAINERD_VER" ge "1.7.28" 2>/dev/null; then
            log_warn "containerd $CONTAINERD_VER on LXC is broken — switching to docker.io..."
            apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
            apt-get update -qq
            apt-get install -y -qq docker.io docker-compose-v2
            systemctl restart docker
        else
            log_ok "Docker already installed (containerd $CONTAINERD_VER, LXC-compatible)"
        fi
    else
        log_ok "Docker already installed: $(docker --version)"
    fi
else
    # Fresh install
    if [ "$IS_LXC" = true ]; then
        # ── LXC path: Ubuntu's docker.io (containerd 1.6.x) ──
        log_warn "Proxmox LXC detected — using docker.io (containerd 1.6.x, LXC-safe)"
        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq docker.io docker-compose-v2
    else
        # ── Bare metal / cloud VM path: official Docker repo ──
        log_info "Installing Docker Engine (official repo)..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable --now docker
fi
log_ok "Docker: $(docker --version)"

# ============================================================
# STEP 2: Create LiteLLM Config
# ============================================================
log_step "Step 2: LiteLLM Configuration"

mkdir -p /opt/litellm

DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

cat > /opt/litellm/litellm_config.yaml << EOF
general_settings:
  master_key: ${LITELLM_MASTER_KEY}
  database_url: ${DATABASE_URL}
  ui: true
  ui_host: "0.0.0.0"
  ui_port: 4000
  disable_spend_logs: false

model_list:
  - model_name: deepseek-chat
    litellm_params:
      model: deepseek/deepseek-v4-pro
      api_key: ${DEEPSEEK_API_KEY}
  - model_name: deepseek-v4-pro
    litellm_params:
      model: deepseek/deepseek-v4-pro
      api_key: ${DEEPSEEK_API_KEY}
  - model_name: deepseek-v4-flash
    litellm_params:
      model: deepseek/deepseek-v4-flash
      api_key: ${DEEPSEEK_API_KEY}
  - model_name: dashscope-vision
    litellm_params:
      model: openai/qwen-vl-max
      api_base: https://ws-9fl3mot986dsg1so.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1
      api_key: ${!_DSK_VN}
      input_cost_per_token: 0.0000008
      output_cost_per_token: 0.0000032
  - model_name: gpt-image-2-hd
    litellm_params:
      model: openai/gpt-image-2
      api_key: ${!_OAI_VN}
      quality: auto
      size: 1024x1024

litellm_settings:
  drop_params: true
  set_verbose: false
  request_timeout: 120

router_settings:
  enable_pre_call_checks: true
  num_retries: 2
  retry_after: 3
EOF

chmod 600 /opt/litellm/litellm_config.yaml
log_ok "Config written to /opt/litellm/litellm_config.yaml"

# Save credentials now (BEFORE container start — Bug #52 fix)
# Previously at STEP 5, which never ran if container failed
cat > /opt/litellm/litellm-credentials.txt << EOF
# Custodian Budget Proxy Credentials
# Generated: $(date)
# Keep this file secure. Do not commit to version control.
LITELLM_MASTER_KEY=${!_LMK_VN}
BUDGET_PROXY_URL=https://${BUDGET_PROXY_DOMAIN}/v1
BUDGET_PROXY_IP=http://${SERVER_IP}:4000/v1
EOF
chmod 600 /opt/litellm/litellm-credentials.txt
log_ok "Credentials saved to /opt/litellm/litellm-credentials.txt (chmod 600)"

# ============================================================
# STEP 3: Deploy LiteLLM
# ============================================================
log_step "Step 3: Deploy LiteLLM"

docker rm -f litellm-proxy 2>/dev/null || true

docker run -d \
  --name litellm-proxy \
  --restart unless-stopped \
  --network host \
  -v /opt/litellm/litellm_config.yaml:/app/config.yaml:ro \
  -e LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}" \
  -e LITELLM_SALT_KEY="${LITELLM_SALT_KEY}" \
  -e DATABASE_URL="${DATABASE_URL}" \
  -e DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY}" \
  -e DASHSCOPE_API_KEY="${!_DSK_VN}" \
  -e STORE_MODEL_IN_DB="true" \
  ghcr.io/berriai/litellm-database:v1.95.0 \
  --config /app/config.yaml --port 4000 --host 0.0.0.0

log_ok "LiteLLM container started"

# ============================================================
# STEP 4: Wait for LiteLLM to be ready
# ============================================================
log_step "Step 4: Wait for LiteLLM"

for i in $(seq 1 30); do
    if curl -s http://localhost:4000/health 2>/dev/null | grep -q '"status"'; then
        log_ok "LiteLLM ready (attempt $i)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        log_error "LiteLLM failed to start after 60s"
        docker logs litellm-proxy --tail 30
        exit 1
    fi
    sleep 2
done

# ============================================================
# STEP 5: Create Admin Virtual Key
# ============================================================
log_step "Step 5: Create Admin Virtual Key"

ADMIN_KEY_RESPONSE=$(curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer ${!_LMK_VN}" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "admin-key",
    "max_budget": 0,
    "budget_duration": "1mo",
    "models": ["deepseek-chat", "deepseek-v4-pro", "deepseek-v4-flash", "dashscope-vision", "gpt-image-2-hd"],
    "metadata": {"user": "admin", "email": "'"${ADMIN_EMAIL}"'"}
  }' 2>/dev/null)

ADMIN_KEY=$(echo "$ADMIN_KEY_RESPONSE" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$ADMIN_KEY" ]; then
    echo "LITELLM_ADMIN_KEY=${ADMIN_KEY}" >> /opt/litellm/litellm-credentials.txt
    log_ok "Admin virtual key created"
else
    log_warn "Could not create admin virtual key (LiteLLM may still be initializing)"
    log_info "Create manually: curl -X POST http://localhost:4000/key/generate -H 'Authorization: Bearer ${!_LMK_VN}'"
fi

# ============================================================
# STEP 6: Verify
# ============================================================
log_step "Step 6: Verify"

# Health check
HEALTH=$(curl -s http://localhost:4000/health 2>/dev/null)
if echo "$HEALTH" | grep -q '"status"'; then
    log_ok "LiteLLM health: $(echo $HEALTH | head -c 80)"
else
    log_warn "LiteLLM health check returned unexpected response"
fi

# Model list (requires master key)
MODELS=$(curl -s http://localhost:4000/v1/models -H "Authorization: Bearer ${!_LMK_VN}" 2>/dev/null)
if echo "$MODELS" | grep -q 'deepseek'; then
    log_ok "DeepSeek models available: $(echo $MODELS | grep -o '"id":"[^"]*"' | head -2 | tr '\n' ' ')"
else
    log_warn "Model list check — may need a moment"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  CUSTODIAN BUDGET PROXY — SETUP COMPLETE${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  Proxy URL:       https://${BUDGET_PROXY_DOMAIN}/v1"
echo "  Local IP:        http://${SERVER_IP}:4000/v1"
echo "  Master Key:      ${LITELLM_MASTER_KEY:0:16}..."
echo "  Admin Key:       ${ADMIN_KEY:-create manually}"
echo ""
echo "  Credentials:     /opt/litellm/litellm-credentials.txt"
echo "  Config:          /opt/litellm/litellm_config.yaml"
echo "  Logs:            docker logs litellm-proxy"
echo ""
echo "  Verify:"
echo "    curl http://localhost:4000/health"
echo "    curl http://localhost:4000/v1/models -H 'Authorization: Bearer ${!_LMK_VN}'"
echo ""
echo "  Create virtual key for a customer:"
echo "    curl -X POST http://localhost:4000/key/generate \\"
echo "      -H 'Authorization: Bearer \${LITELLM_MASTER_KEY}' \\\\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d '{\"key_alias\":\"customer-name\",\"max_budget\":10,\"models\":[\"deepseek-chat\"]}'"
echo ""
