1|1|#!/bin/bash
2|2|# Custodian Customer Server Setup
3|3|# Routes ALL AI requests through Budget Proxy (LiteLLM)
4|4|#
5|5|# One-liner:
6|6|#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | sudo bash
7|7|
8|8|set -euo pipefail
9|9|
10|10|RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
11|11|log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }
12|12|log_ok()    { echo -e "  ${GREEN}OK:${NC} $1"; }
13|13|log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }
14|14|log_warn()  { echo -e "  ${YELLOW}WARN:${NC} $1"; }
15|15|log_info()  { echo -e "  -> $1"; }
16|16|
17|17|[ "$(id -u)" -ne 0 ] && { log_error "Must run as root"; exit 1; }
18|18|
19|19|# Auto-generate virtual key if not provided (requires LITELLM_MASTER_KEY)
20|20|if [ -z "${CUSTOMER_API_KEY:-}" ]; then
21|21|  if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
22|22|    echo "ERROR: CUSTOMER_API_KEY or LITELLM_MASTER_KEY is required"
23|23|    echo "  Provide CUSTOMER_API_KEY directly, or set LITELLM_MASTER_KEY for auto-generation"
24|24|    exit 1
25|25|  fi
26|26|  log_info "Auto-generating virtual key via Budget Proxy..."
27|27|  KEY_RESPONSE=$(curl -s -X POST "${BUDGET_PROXY_URL%/v1}/key/generate" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
29|29|    -H "Content-Type: application/json" \
30|30|    -d "{\"key_alias\": \"${CUSTOMER_ID:-custodian}\", \"models\": [\"deepseek-v4-pro\"], \"max_budget\": ${MAX_BUDGET:-25}, \"budget_duration\": \"1mo\"}" 2>/dev/null)
  CUSTOMER_API_KEY=$(echo "$KEY_RESPONSE" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)
32|32|  if [ -z "${CUSTOMER_API_KEY}" ]; then
33|33|    echo "ERROR: Failed to auto-generate API key. Response:"
34|34|    echo "$KEY_RESPONSE" | head -5
35|35|    exit 1
36|36|  fi
  export CUSTOMER_API_KEY="${CUSTOMER_API_KEY}"
38|38|  log_ok "Virtual key generated: ${CUSTOMER_API_KEY:0:16}..."
39|39|fi
40|40|
41|41|# Configuration
42|42|CUSTOMER_API_KEY="${CUSTOMER_API_KEY}"
43|43|BUDGET_PROXY_URL="${BUDGET_PROXY_URL:-https://budget.ns1net.com/v1}"
44|44|PORT="${PORT:-8642}"
45|45|WEBUI_PORT="${WEBUI_PORT:-3000}"
46|46|CUSTOMER_ID="${CUSTOMER_ID:-custodian}"
47|47|MAX_BUDGET="${MAX_BUDGET:-25}"
48|48|[ -z "${API_SERVER_KEY:-}" ] && export API_SERVER_KEY=$(openssl rand -hex 32)
49|49|[ -z "${WEBUI_SECRET_KEY:-}" ] && export WEBUI_SECRET_KEY=$(openssl rand -hex 32)
50|50|
51|51|# Hermes version pin -- update when upgrading
52|52|# Find current: docker run --rm nousresearch/hermes-agent:latest hermes --version
53|53|HERMES_PINNED_VERSION="v2026.7.20"
54|54|HERMES_PINNED_DIGEST="sha256:0e06e95613c7536e14f33e9dd5f7c15db676fc25c6c13e350c69ce47e1464033"
55|55|
56|56|SERVER_IP=$(hostname -I | awk '{print $1}')
57|57|COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.custodian-factory.yml"
58|58|
59|59|log_step 'Step 0: Timezone'
60|60|timedatectl set-timezone America/Chicago 2>/dev/null || true
61|61|log_ok 'Timezone set'
62|62|
63|63|log_step 'Step 1: System Update'
64|64|export DEBIAN_FRONTEND=noninteractive
65|65|apt-get update -qq && apt-get upgrade -y -qq
66|66|apt-get install -y -qq ca-certificates curl openssl
67|67|log_ok 'System updated'
68|68|
69|69|log_step 'Step 2: Docker'
70|70|
71|71|# ── Auto-detect Proxmox LXC ──
72|72|# docker-ce pulls containerd 1.7.x which triggers
73|73|# "ip_unprivileged_port_start: permission denied" inside LXC.
74|74|# docker.io ships containerd 1.6.x which works in LXC.
75|75|# See: research/proxmox-lxc-containerd-fix-plan.md
76|76|IS_LXC=false
77|77|if [ -f /run/systemd/container ]; then
78|78|    CT_TYPE=$(cat /run/systemd/container 2>/dev/null || echo "")
79|79|    [ "$CT_TYPE" = "lxc" ] || [ "$CT_TYPE" = "lxc-libvirt" ] && IS_LXC=true
80|80|fi
81|81|grep -qa 'lxc' /proc/1/environ 2>/dev/null && IS_LXC=true
82|82|[ -d /dev/lxd ] || [ -d /var/lib/lxc ] && IS_LXC=true
83|83|
84|84|# Install or fix Docker (LXC-aware with containerd version check)
85|85|if command -v docker &>/dev/null; then
86|86|    if [ "$IS_LXC" = true ]; then
87|87|        CONTAINERD_VER=$(containerd --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.0")
88|88|        if dpkg --compare-versions "$CONTAINERD_VER" ge "1.7.28" 2>/dev/null; then
89|89|            log_warn "containerd $CONTAINERD_VER on LXC is broken — switching to docker.io..."
90|90|            apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
91|91|            apt-get update -qq
92|92|            apt-get install -y -qq docker.io docker-compose-v2
93|93|            systemctl restart docker
94|94|        else
95|95|            log_info "Docker already installed (containerd $CONTAINERD_VER, LXC-compatible)"
96|96|        fi
97|97|    else
98|98|        log_info "Docker already installed: $(docker --version)"
99|99|    fi
100|100|else
101|101|    if [ "$IS_LXC" = true ]; then
102|102|        log_warn "Proxmox LXC detected — using docker.io (containerd 1.6.x, LXC-safe)"
103|103|        apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
104|104|        apt-get update -qq
105|105|        apt-get install -y -qq docker.io docker-compose-v2
106|106|    else
107|107|        log_info "Installing Docker Engine (official repo)..."
108|108|        install -m 0755 -d /etc/apt/keyrings
109|109|        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
110|110|        chmod a+r /etc/apt/keyrings/docker.asc
111|111|        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
112|112|        apt-get update -qq
113|113|        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
114|114|    fi
115|115|    systemctl enable --now docker
116|116|fi
117|117|log_ok "Docker: $(docker --version)"
118|118|
119|119|log_step 'Step 3: Pull Hermes'
120|120|HERMES_IMAGE="nousresearch/hermes-agent:${HERMES_PINNED_VERSION}"
121|121|if [ "${SKIP_HERMES:-0}" != "1" ]; then
122|122|  docker pull "$HERMES_IMAGE"
123|123|  ACTUAL_VERSION=$(docker run --rm "$HERMES_IMAGE" hermes --version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' | head -1 || echo "unknown")
124|124|  if [ "$ACTUAL_VERSION" != "${HERMES_PINNED_VERSION}" ] && [ "$ACTUAL_VERSION" != "unknown" ]; then
125|125|    echo ""
126|126|    echo "  =============================================="
127|127|    echo "  ${YELLOW}WARNING: HERMES VERSION MISMATCH${NC}"
128|128|    echo "  Expected: ${HERMES_PINNED_VERSION}"
129|129|    echo "  Got:      $ACTUAL_VERSION"
130|130|    echo "  The image tag has been updated."
131|131|    echo "  Update HERMES_PINNED_VERSION in setup-custodian-factory.sh"
132|132|    echo "  and docker-compose.custodian-factory.yml"
133|133|    echo "  =============================================="
134|134|    echo ""
135|135|  fi
136|136|fi
137|137|log_ok "Hermes image ready (pinned: ${HERMES_PINNED_VERSION})" 
138|138|
139|139|log_step 'Step 4: Deploy Stack'
140|140|[ ! -f docker-compose.custodian-factory.yml ] && curl -sS -o docker-compose.custodian-factory.yml "$COMPOSE_URL"
141|141|
142|142|  BUDGET_PROXY_URL="${BUDGET_PROXY_URL}" \
143|143|  API_SERVER_KEY="${API_SERVER_KEY}" \
144|144|  PORT=$PORT WEBUI_PORT=$WEBUI_PORT CUSTOMER_ID=$CUSTOMER_ID \
145|145|  docker compose -p $CUSTOMER_ID -f docker-compose.custodian-factory.yml up -d
146|146|
147|147|# Save .env (namespaced by CUSTOMER_ID — prevents overwrite when adding more customers)
148|148|cat > .env.${CUSTOMER_ID}-factory << EOF
149|149|API_SERVER_KEY=${API_SERVER_KEY}
150|150|WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
151|151|CUSTOMER_API_KEY=${CUSTOMER_API_KEY}
152|152|BUDGET_PROXY_URL=${BUDGET_PROXY_URL}
153|153|EOF
154|154|chmod 600 .env.${CUSTOMER_ID}-factory
155|155|log_ok 'Keys saved'
156|156|
157|157|log_step 'Step 5: Configure Hermes Routing'
158|158|sleep 15
159|159|HERMES_CONTAINER="$CUSTOMER_ID-hermes"
160|160|# Use custom provider for OpenAI-compatible endpoints (LiteLLM)
161|161|# Hermes v0.19+ requires "custom"; older versions used "openai"
162|162|docker exec $HERMES_CONTAINER hermes config set model.provider custom 2>/dev/null || true
163|163|docker exec $HERMES_CONTAINER hermes config set model.base_url "${BUDGET_PROXY_URL}" 2>/dev/null || true
164|164|docker exec $HERMES_CONTAINER hermes config set model.default deepseek-v4-pro 2>/dev/null || true
165|165|docker exec $HERMES_CONTAINER hermes config set platforms.api_server.extra.model_name "Custodian AI" 2>/dev/null || true
166|166|docker exec $HERMES_CONTAINER hermes config set model.api_key "${CUSTOMER_API_KEY}" || true
167|167|docker exec $HERMES_CONTAINER hermes config set web.search_backend searxng 2>/dev/null || true
168|168|docker exec $HERMES_CONTAINER hermes config set web.searxng.base_url "http://searxng:8080" 2>/dev/null || true
169|169|log_ok "Hermes routing: deepseek-chat -> ${BUDGET_PROXY_URL} (display: Custodian AI) + SearXNG"
170|170|
171|171|log_step 'Step 6: Verify'
172|172|sleep 10
173|173|HERMES_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PORT:-8642}/v1/health 2>/dev/null || echo 000)
174|174|OWUI_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${WEBUI_PORT:-3000} 2>/dev/null || echo 000)
175|175|echo "  Hermes: HTTP $HERMES_CODE | Open WebUI: HTTP $OWUI_CODE"
176|176|
177|177|echo ''
178|178|echo '=== CUSTODIAN — READY ==='
179|179|echo "  Open WebUI:  http://${SERVER_IP}:${WEBUI_PORT:-3000}"
180|180|echo "  Hermes API:  http://${SERVER_IP}:${PORT:-8642}/v1"
181|181|echo "  Budget Proxy: ${BUDGET_PROXY_URL}"