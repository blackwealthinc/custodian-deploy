#!/bin/bash
# Custodian — Standalone Deployment Health Check
# Run anytime to diagnose the full Custodian stack.
# Safe to run repeatedly — read-only, no changes made.
#
# One-liner:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/verify-deployment.sh | sudo -E bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS="${GREEN}PASS${NC}"; FAIL="${RED}FAIL${NC}"; WARN="${YELLOW}WARN${NC}"; SKIP="${CYAN}SKIP${NC}"

PASSED=0; FAILED=0; WARNINGS=0

check() {
  local label="$1" result="$2" detail="${3:-}"
  case "$result" in
    PASS) echo -e "  ${PASS}  $label${detail:+ — $detail}"; PASSED=$((PASSED+1)) ;;
    FAIL) echo -e "  ${FAIL}  $label${detail:+ — $detail}"; FAILED=$((FAILED+1)) ;;
    WARN) echo -e "  ${WARN}  $label${detail:+ — $detail}"; WARNINGS=$((WARNINGS+1)) ;;
    SKIP) echo -e "  ${SKIP}  $label${detail:+ — $detail}" ;;
  esac
}

echo ''
echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Custodian Health Check            ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo "  $(date)"
echo "  Server: $(hostname -I | awk '{print $1}')"
echo ''

# ─────────────────────────────────────────────
echo -e "${CYAN}── Docker ──────────────────────────────${NC}"

if command -v docker &>/dev/null; then
  check "Docker installed" PASS "$(docker --version | cut -d' ' -f1-3)"
  if docker info &>/dev/null; then
    check "Docker running" PASS
  else
    check "Docker running" FAIL "daemon not responding"
  fi
else
  check "Docker installed" FAIL "not found"
fi

# ─────────────────────────────────────────────
echo -e "${CYAN}── Networks ────────────────────────────${NC}"

if docker network inspect searxng-net &>/dev/null; then
  check "searxng-net" PASS "exists"
else
  check "searxng-net" FAIL "missing — run setup-searxng.sh first"
fi

# Find customer networks (excluding default Docker nets)
CUSTOMER_NETS=$(docker network ls --format '{{.Name}}' | grep -vE '^(bridge|host|none|searxng-net)$' || true)
if [ -n "$CUSTOMER_NETS" ]; then
  check "Customer network(s)" PASS "$(echo "$CUSTOMER_NETS" | tr '\n' ' ')"
else
  check "Customer network(s)" WARN "none — run setup-custodian-factory.sh"
fi

# ─────────────────────────────────────────────
echo -e "${CYAN}── SearXNG ─────────────────────────────${NC}"

SEARXNG_HEALTHY=false
if docker ps --format '{{.Names}}' | grep -q 'searxng$'; then
  HEALTH=$(docker inspect searxng --format '{{.State.Health.Status}}' 2>/dev/null || echo "none")
  if [ "$HEALTH" = "healthy" ]; then
    check "SearXNG container" PASS "healthy"
    SEARXNG_HEALTHY=true
  else
    check "SearXNG container" FAIL "running but not healthy (status: $HEALTH)"
  fi
else
  check "SearXNG container" FAIL "not running — docker compose up -d in /opt/searxng"
fi

# Actual search test
if $SEARXNG_HEALTHY; then
  SEARCH_RESULT=$(curl -s --connect-timeout 5 "http://localhost:8888/search?q=health+check&format=json" 2>/dev/null || echo "")
  if echo "$SEARCH_RESULT" | grep -q '"results"'; then
    RESULT_COUNT=$(echo "$SEARCH_RESULT" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('results',[])))" 2>/dev/null || echo "?")
    check "SearXNG search" PASS "$RESULT_COUNT results returned"
  else
    check "SearXNG search" FAIL "no results — check: docker logs searxng"
  fi
else
  check "SearXNG search" SKIP "container not healthy"
fi

# DNS check from a customer container
HERMES_CONTAINER=$(docker ps --format '{{.Names}}' | grep 'hermes' | head -1 || echo "")
if [ -n "$HERMES_CONTAINER" ]; then
  if docker exec "$HERMES_CONTAINER" getent hosts searxng >/dev/null 2>&1; then
    SEARXNG_IP=$(docker exec "$HERMES_CONTAINER" getent hosts searxng | awk '{print $1}')
    check "SearXNG DNS" PASS "resolves to $SEARXNG_IP from $HERMES_CONTAINER"
  else
    check "SearXNG DNS" WARN "not resolving — connect hermes to searxng-net"
  fi
else
  check "SearXNG DNS" SKIP "no hermes container found"
fi

# ─────────────────────────────────────────────
echo -e "${CYAN}── Hermes ──────────────────────────────${NC}"

CUSTOMER_IDS=$(docker ps --format '{{.Names}}' | grep 'hermes' | sed 's/-hermes//' || echo "")

if [ -z "$CUSTOMER_IDS" ]; then
  check "Hermes" FAIL "no hermes containers running"
else
  for CID in $CUSTOMER_IDS; do
    HNAME="${CID}-hermes"
    HERMES_PORT=8642  # default; could parse from docker port
    
    # Container status
    if docker ps --format '{{.Names}}' | grep -q "^${HNAME}$"; then
      
      # Health endpoint
      HERMES_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://localhost:8642/v1/health" 2>/dev/null || echo 000)
      if [ "$HERMES_CODE" = "200" ]; then
        check "Hermes ($CID)" PASS "health OK"
      else
        check "Hermes ($CID)" FAIL "health HTTP $HERMES_CODE"
      fi
      
      # Models endpoint (proves Budget Proxy connection)
      MODELS_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://localhost:8642/v1/models" 2>/dev/null || echo 000)
      if [ "$MODELS_CODE" = "200" ]; then
        MODEL_COUNT=$(curl -s --connect-timeout 5 "http://localhost:8642/v1/models" 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "?")
        check "Budget Proxy ($CID)" PASS "$MODEL_COUNT models via proxy"
      else
        check "Budget Proxy ($CID)" FAIL "HTTP $MODELS_CODE — check Budget Proxy on VM205"
      fi
      
      # Image version
      IMAGE=$(docker inspect "$HNAME" --format '{{.Config.Image}}' 2>/dev/null || echo "unknown")
      check "Hermes image ($CID)" PASS "$IMAGE"
      
    else
      check "Hermes ($CID)" FAIL "container not running"
    fi
  done
fi

# ─────────────────────────────────────────────
echo -e "${CYAN}── Open WebUI ──────────────────────────${NC}"

for CID in $CUSTOMER_IDS; do
  WNAME="${CID}-webui"
  WEBUI_PORT=3000
  
  if docker ps --format '{{.Names}}' | grep -q "^${WNAME}$"; then
    OWUI_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://localhost:${WEBUI_PORT}" 2>/dev/null || echo 000)
    if [ "$OWUI_CODE" = "200" ] || [ "$OWUI_CODE" = "302" ]; then
      check "WebUI ($CID)" PASS "HTTP $OWUI_CODE on port $WEBUI_PORT"
    else
      check "WebUI ($CID)" FAIL "HTTP $OWUI_CODE — may need more time if models downloading"
    fi
  else
    check "WebUI ($CID)" WARN "container not running"
  fi
done

# ─────────────────────────────────────────────
echo -e "${CYAN}── Docker Images ────────────────────────${NC}"

IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '(hermes|open-webui|searxng|valkey)' | sort || true)
if [ -n "$IMAGES" ]; then
  echo "$IMAGES" | while read img; do
    SIZE=$(docker images "$img" --format '{{.Size}}' 2>/dev/null || echo "?")
    echo -e "       $img ($SIZE)"
  done
  check "Custodian images" PASS "$(echo "$IMAGES" | wc -l) images present"
else
  check "Custodian images" WARN "no custodian images found"
fi

# ─────────────────────────────────────────────
echo ''
echo -e "${BLUE}═══════════════════════════════════════════${NC}"
echo -e "  ${GREEN}PASS: $PASSED${NC}  ${RED}FAIL: $FAILED${NC}  ${YELLOW}WARN: $WARNINGS${NC}"
echo ''

if [ $FAILED -gt 0 ]; then
  echo -e "  ${RED}ISSUES DETECTED — See FAIL items above${NC}"
  echo ''
  echo '  Common fixes:'
  echo '    Missing SearXNG:    curl -s ...setup-searxng.sh | sudo -E bash'
  echo '    Missing Hermes/WebUI: curl -s ...setup-custodian-factory.sh | sudo -E bash'
  echo '    SearXNG not started: cd /opt/searxng && docker compose up -d'
elif [ $WARNINGS -gt 0 ]; then
  echo -e "  ${YELLOW}OK with warnings — review WARN items above${NC}"
else
  echo -e "  ${GREEN}ALL CHECKS PASSED — Custodian is healthy${NC}"
fi

echo ''
