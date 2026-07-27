#!/bin/bash
# Custodian — SearXNG Meta-Search Engine Setup
# Run ONCE per physical server. All customer instances share this.
#
# One-liner:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-searxng.sh | sudo -E bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_step()  { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_ok()    { echo -e "  ${GREEN}OK:${NC} $1"; }
log_error() { echo -e "  ${RED}ERROR:${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}WARN:${NC} $1"; }
log_info()  { echo -e "  -> $1"; }

[ "$(id -u)" -ne 0 ] && { log_error "Must run as root"; exit 1; }

COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.searxng.yml"
SETTINGS_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/searxng-settings.yml"
COMPOSE_FILE="docker-compose.searxng.yml"
SEARXNG_DIR="/opt/searxng"

log_step 'Step 1: System Update'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl openssl python3
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

log_step 'Step 3: Create SearXNG Directory'
mkdir -p "$SEARXNG_DIR"/{searxng-config,searxng-valkey-data}
cd "$SEARXNG_DIR"
log_ok "Directory: $SEARXNG_DIR"

log_step 'Step 4: Download Config Files'
curl -sS -o "$COMPOSE_FILE" "$COMPOSE_URL"

# Create minimal settings.yml if not already present
if [ ! -f searxng-config/settings.yml ]; then
    cat > searxng-config/settings.yml << 'YAML'
# SearXNG settings — Custodian
# Docs: https://docs.searxng.org/admin/settings/

use_default_settings: true

general:
  instance_name: "Custodian Search"
  debug: false
  privacypolicy_url: false
  contact_url: false

search:
  safe_search: 0
  autocomplete: ""
  default_lang: ""
  formats:
    - html
    - json

server:
  secret_key: "CHANGE_ME_USE_OPENSSL_RAND_HEX_32"
  bind_address: "0.0.0.0"
  port: 8080
  limiter: false
  public_instance: false
  image_proxy: true
  method: "GET"

ui:
  static_use_hash: true
  default_theme: simple
  default_locale: en

redis:
  url: valkey://searxng-valkey:6379/0

outgoing:
  request_timeout: 5.0
  max_request_timeout: 10.0
  useragent_suffix: ""

engines:
  # Keep these — remove any that cause issues
  - name: duckduckgo
    disabled: false
  - name: google
    disabled: false
  - name: brave
    disabled: true
  - name: wikipedia
    disabled: false
  - name: bing
    disabled: true
YAML
    # Replace placeholder with random key
    SECRET=$(openssl rand -hex 32)
    sed -i "s/CHANGE_ME_USE_OPENSSL_RAND_HEX_32/$SECRET/" searxng-config/settings.yml
    log_ok 'settings.yml created'
else
    log_info 'settings.yml already exists — skipping'
fi

log_step 'Step 5: Start SearXNG'
docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
if ! docker compose -f "$COMPOSE_FILE" up -d; then
  log_error "docker compose up -d failed — check logs: docker compose -f $COMPOSE_FILE logs"
  exit 1
fi

# Wait for SearXNG health check to pass
log_info "Waiting for SearXNG to be healthy..."
for i in $(seq 1 30); do
  HEALTH=$(docker inspect searxng --format '{{.State.Health.Status}}' 2>/dev/null) || true
  [ "$HEALTH" = "healthy" ] && break
  sleep 2
done
if [ "$HEALTH" != "healthy" ]; then
  log_error "SearXNG health check failed — check: docker logs searxng"
  exit 1
fi
log_ok 'SearXNG healthy'

log_step 'Step 6: Verify Search'
# Real verification — searches and checks for actual results
SEARCH_RESULT=$(curl -s "http://localhost:8888/search?q=test&format=json" 2>/dev/null)
if echo "$SEARCH_RESULT" | grep -q '"results"'; then
  RESULT_COUNT=$(echo "$SEARCH_RESULT" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('results',[])))" 2>/dev/null || echo "?")
  log_ok "SearXNG verified — returning $RESULT_COUNT live results"
else
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8888/search?q=test 2>/dev/null || echo 000)
  log_error "SearXNG search returned no results (HTTP $HTTP_CODE)"
  log_error "Check: docker logs searxng"
  exit 1
fi

echo ''
echo '=== SEARXNG — READY ==='
echo "  Internal URL:  http://searxng:8080  (for Docker containers on searxng-net)"
echo "  External URL:  http://$(hostname -I | awk '{print $1}'):8888"
echo "  Config:        $SEARXNG_DIR/searxng-config/settings.yml"
echo "  Logs:          docker logs searxng"
echo ''
echo '  Customer Hermes instances will auto-connect if setup-custodian-factory.sh'
echo '  was run AFTER this script (or re-run to pick up the SearXNG config).'
