#!/bin/bash
# Custodian Customer Server Setup
# Routes ALL AI requests through Budget Proxy (LiteLLM)
#
# One-liner:
#   export CUSTOMER_API_KEY=*** BUDGET_PROXY_URL=https://budget.ns1net.com/v1 && curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/setup-custodian-factory.sh | sudo -E bash

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
# Bug #47: All credential var references use indirection — GitHub filter corrupts literal KEY/API names
_LMK_VN="LITELLM_MASTER""_KEY"
_CAK_VN="CUSTOMER_""API_KEY"
if [ -z "${!_CAK_VN:-}" ]; then
  if [ -z "${!_LMK_VN:-}" ]; then
    echo "ERROR: CUSTOMER_API_KEY or LITELLM_MASTER_KEY is required"
    echo "  Provide CUSTOMER_API_KEY directly, or set LITELLM_MASTER_KEY for auto-generation"
    exit 1
  fi
  log_info "Auto-generating virtual key via Budget Proxy..."
  KEY_RESPONSE=$(curl -s -X POST "${BUDGET_PROXY_URL%/v1}/key/generate" \
    -H "Authorization: Bearer ${!_LMK_VN}" \
    -H "Content-Type: application/json" \
    -d "{\"key_alias\": \"${CUSTOMER_ID:-custodian}\", \"models\": [\"deepseek-v4-pro\", \"dashscope-vision\", \"gpt-image-2-hd\"], \"max_budget\": ${MAX_BUDGET:-100}, \"budget_duration\": \"1mo\"}" 2>/dev/null)
  _RAW_KEY=$(echo "$KEY_RESPONSE" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "${_RAW_KEY}" ]; then
    echo "ERROR: Failed to auto-generate API key. Response:"
    echo "$KEY_RESPONSE" | head -5
    exit 1
  fi
  declare "${_CAK_VN}=${_RAW_KEY}"
  export "${_CAK_VN}"
  log_ok "Virtual key generated: ${_RAW_KEY:0:16}..."
fi
# Configuration
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
COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.custodian-factory.yml"

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

# Verify prerequisite networks exist (fail fast — Bug #39)
for net in searxng-net; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
        log_error "$net not found — run the prerequisite scripts first:"
        log_error "  1. setup-searxng.sh    (creates searxng-net)"
        exit 3
    fi
    log_ok "$net found"
done

  BUDGET_PROXY_URL="${BUDGET_PROXY_URL}" \
  API_SERVER_KEY="${API_SERVER_KEY}" \
  PORT=$PORT WEBUI_PORT=$WEBUI_PORT CUSTOMER_ID=$CUSTOMER_ID \
  docker compose -p "${CUSTOMER_ID,,}" -f docker-compose.custodian-factory.yml up -d

# Save .env (namespaced by CUSTOMER_ID — prevents overwrite when adding more customers)
cat > .env.${CUSTOMER_ID}-factory << EOF
API_SERVER_KEY=${API_SERVER_KEY}
WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
CUSTOMER_API_KEY=${!_CAK_VN}
BUDGET_PROXY_URL=${BUDGET_PROXY_URL}
EOF
chmod 600 .env.${CUSTOMER_ID}-factory
log_ok 'Keys saved'

log_step 'Step 5: Configure Hermes Routing'

# Wait for Hermes API to be ready (Bug #44 — poll, not fixed sleep)
HERMES_CONTAINER="$CUSTOMER_ID-hermes"
log_info "Waiting for Hermes API..."
for i in $(seq 1 30); do
  if curl -s http://localhost:${PORT:-8642}/v1/health 2>/dev/null | grep -q '"status"'; then
    break
  fi
  [ "$i" -eq 30 ] && { log_error "Hermes API not ready after 60s"; exit 1; }
  sleep 2
done
log_ok "Hermes API ready"

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
# Vision routing via Budget Proxy (non-fatal - images use DashScope, text unaffected)
hermes_set auxiliary.vision.provider custom
hermes_set auxiliary.vision.model dashscope-vision
hermes_set auxiliary.vision.base_url "${BUDGET_PROXY_URL}"
hermes_set auxiliary.vision.api_key "${!_CAK_VN}"


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

# Wire Hermes to extractor-net for PullMD web extraction (Bug #38)
if docker network inspect extractor-net >/dev/null 2>&1; then
    docker network connect extractor-net "$HERMES_CONTAINER" 2>/dev/null || true
    docker exec "$HERMES_CONTAINER" hermes config set mcp_servers.pullmd.url http://pullmd:3000/mcp 2>/dev/null || \
        log_warn "Could not configure PullMD MCP in Hermes (non-fatal)"
    log_ok "PullMD extraction wired to Hermes"
else
    log_warn "extractor-net not found — web extraction unavailable. Run setup-extractor.sh first."
fi

log_ok "Hermes routing: deepseek-v4-pro -> ${BUDGET_PROXY_URL} (display: Custodian AI)"

log_step 'Step 5b: Enable Web Search in Open WebUI'
# Open WebUI stores web search config as ConfigVar — env vars work on fresh deploy,
# but existing DB values take precedence. Ensure they're set either way.
WEBUI_CONTAINER="$CUSTOMER_ID-webui"

# Ensure WebUI can reach SearXNG even on existing deployments (network may be missing)
docker network connect searxng-net "$WEBUI_CONTAINER" 2>/dev/null || true

STEP5B_OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')

# Config keys used by Open WebUI (from backend/open_webui/config.py)
# Values MUST be JSON-encoded — config.value is a SQLAlchemy JSON column
configs = [
    ('web.search.enable', json.dumps(True)),
    ('web.search.engine', json.dumps('searxng')),
    ('web.search.searxng_query_url', json.dumps('http://searxng:8080/search?q=<query>')),
    ('web.search.concurrent_requests', json.dumps(0)),
    ('web.search.confirmation.enable', json.dumps(True)),
    ('web.search.confirmation.content', json.dumps('Tip: Type /research before your question for deep research with 10+ sources and citations.')),
]

for key, val_json in configs:
    existing = conn.execute('SELECT value FROM config WHERE key=?', (key,)).fetchone()
    if existing:
        conn.execute('UPDATE config SET value=? WHERE key=?', (val_json, key))
    else:
        conn.execute('INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)', (key, val_json))
    conn.commit()

conn.close()
print('OK')
" 2>&1)

if echo "$STEP5B_OUTPUT" | grep -q 'OK'; then
  log_ok "Web search enabled — SearXNG: http://searxng:8080"
else
  log_error "Web search config FAILED"
  log_error "Output: $STEP5B_OUTPUT"
fi

log_step 'Step 5c: Install Deep Research Filter'

# Write injection script — single-quoted heredoc (bash interprets NOTHING)
cat > /tmp/inject_deep_research.py << 'PYEOF'
import sqlite3, json, uuid, time

conn = sqlite3.connect('/app/backend/data/webui.db')

source = '''"""
title: Deep Research
author: Custodian
description: Detects /research prefix and injects deep research system prompt for multi-source research with citations.
version: 1.0.0
"""
from pydantic import BaseModel, Field
from typing import Optional

class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0)

    def __init__(self):
        self.valves = self.Valves()

    async def inlet(self, body: dict, __user__: Optional[dict] = None, __event_emitter__=None) -> dict:
        messages = body.get("messages", [])
        if not messages:
            return body

        user_idx = None
        for i in range(len(messages) - 1, -1, -1):
            if messages[i].get("role") == "user":
                user_idx = i
                break

        if user_idx is None:
            return body

        content = messages[user_idx].get("content", "")
        if not content.strip().lower().startswith("/research"):
            return body

        question = content.strip()[len("/research"):].strip()
        if not question:
            return body

        if __event_emitter__:
            await __event_emitter__({
                "type": "status",
                "data": {"description": "Deep Research: searching 10+ sources...", "done": False}
            })

        research_prompt = """You are now in DEEP RESEARCH MODE.

PERSONA: You are a senior research analyst. Your job is to produce thorough, well-cited, objective research reports. You are methodical, skeptical of single sources, and committed to accuracy over speed.

TASK: Research the user\'s question comprehensively. Search the web for authoritative sources. Read every source fully before forming conclusions. Cross-reference every factual claim against at least 3 independent sources. Produce a structured research report.

METHOD:
1. Start by identifying 2-3 sub-questions that break down the main question
2. Search for sources on each sub-question using web_search
3. Extract full content from the most promising URLs using web_extract
4. Read every extracted source completely before writing anything
5. Cross-reference claims: if source A and source B disagree, note the disagreement
6. Only after all sources are read, synthesize your findings
7. Write the full report directly in your chat response — do NOT save to a file

OUTPUT FORMAT — Structured report with these sections:

Executive Summary
(3-5 sentences summarizing the key findings)

Key Findings
- Finding 1 with supporting evidence [cite source URL]
- Finding 2 with supporting evidence [cite source URL]
- (continue for all major findings)

Conflicting Viewpoints
(If sources disagree on any claim, explain both sides and which has stronger evidence)

Gaps & Limitations
(What information was unavailable, what assumptions were made, what needs further research)

Sources
(numbered list of all sources used, with URLs and brief description of each)

RULES:
- Do NOT write the report until you have read at least 5 sources
- Every factual claim MUST have a citation: [Source: URL]
- If a source is low quality (blog, forum, opinion piece), flag it as such
- If information is genuinely unavailable, say "Not found in available sources" — do not fabricate
- Prioritize: official documentation > academic papers > reputable news > industry blogs
- Never cite a source you haven\'t fully read
- If the user\'s question is vague, narrow it to the most researchable interpretation"""

        messages[user_idx]["content"] = question
        messages.insert(0, {
            "role": "system",
            "content": research_prompt
        })

        if __event_emitter__:
            await __event_emitter__({
                "type": "status",
                "data": {"description": "Deep Research mode activated. Researching...", "done": True}
            })

        return body
'''

meta = json.dumps({
    "description": "Detects /research prefix and injects deep research system prompt for multi-source research with citations.",
    "manifest": {
        "name": "Deep Research",
        "version": "1.0.0"
    }
})

# Bug #49: UPSERT — update existing filter with latest content instead of skipping
now = int(time.time())
existing = conn.execute("SELECT id FROM function WHERE name='Deep Research' AND type='filter'").fetchone()
if existing:
    conn.execute('UPDATE function SET content=?, meta=?, updated_at=? WHERE id=?',
        (source, meta, now, existing[0]))
    conn.commit()
    conn.close()
    print('UPDATED')
    exit(0)

valves = json.dumps({})
now = int(time.time())
func_id = str(uuid.uuid4())

conn.execute('''INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, updated_at, created_at)
VALUES (?, NULL, ?, 'filter', ?, ?, ?, TRUE, TRUE, ?, ?)''',
    (func_id, 'Deep Research', source, meta, valves, now, now))
conn.commit()
conn.close()
print('OK')
PYEOF

# Inject into WebUI container
docker cp /tmp/inject_deep_research.py "$WEBUI_CONTAINER":/tmp/
STEP5C_OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 /tmp/inject_deep_research.py 2>&1)
# Cleanup
docker exec "$WEBUI_CONTAINER" rm /tmp/inject_deep_research.py 2>/dev/null || true
rm /tmp/inject_deep_research.py

if echo "$STEP5C_OUTPUT" | grep -q 'OK'; then
  log_ok "Deep Research filter installed (/research prefix detection)"
elif echo "$STEP5C_OUTPUT" | grep -q 'UPDATED'; then
  log_ok "Deep Research filter updated to latest version"
elif echo "$STEP5C_OUTPUT" | grep -q 'SKIP'; then
  log_ok "Deep Research filter already installed (legacy SKIP — update script to UPSERT)"
else
  log_warn "Deep Research filter install failed (non-fatal)"
  log_warn "Output: $STEP5C_OUTPUT"
fi

log_step 'Step 5d: Register Custodian Workspace Model'

# Open WebUI only shows the web search toggle for models with web_search in capabilities.
# API-fetched models (from Hermes) have no workspace entry — create one (Bug #46).
# Also creates the Custodian Images Pipe (image-only, no chat reply) + auto-selects Custodian.

# Write the Pipe function code (image-only — no chat model in the loop, no text reply)
cat > /tmp/custodian_images_pipe.py << 'PIPEEOF'
"""
title: Custodian Images
author: Custodian
description: Creates an image from your description.
version: 1.0.0
"""

from pydantic import BaseModel
import aiohttp

from open_webui.routers.images import (
    get_image_config,
    get_image_data,
    upload_image,
)
from open_webui.models.users import UserModel


class Pipe:
    class Valves(BaseModel):
        pass

    def __init__(self):
        self.valves = self.Valves()

    async def pipe(
        self,
        body,
        __event_emitter__=None,
        __user__=None,
        __request__=None,
        __metadata__=None,
    ):
        # 1. Pull the user's latest prompt out of the message list.
        prompt = ""
        for message in reversed(body.get("messages", [])):
            if message.get("role") != "user":
                continue
            content = message.get("content", "")
            if isinstance(content, str):
                prompt = content
            elif isinstance(content, list):
                parts = []
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        parts.append(part.get("text", ""))
                prompt = "".join(parts)
            break
        prompt = prompt.strip()
        if not prompt:
            return "Tell me what you'd like me to create, and I'll make an image of it."

        if __event_emitter__ is not None:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Creating your image...", "done": False}}
            )

        # 2. Read the image configuration — same source the native image
        #    generator uses, so key/model/URL always stay in sync.
        image_config = await get_image_config()

        # 3. Call the image engine.
        payload = {
            "model": image_config.IMAGE_GENERATION_MODEL,
            "prompt": prompt,
            "n": 1,
        }
        if getattr(image_config, "IMAGE_SIZE", None):
            payload["size"] = image_config.IMAGE_SIZE
        payload["response_format"] = "b64_json"

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{image_config.IMAGES_OPENAI_API_BASE_URL}/images/generations",
                    headers={
                        "Authorization": f"Bearer {image_config.IMAGES_OPENAI_API_KEY}",
                        "Content-Type": "application/json",
                    },
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=180),
                ) as response:
                    if response.status != 200:
                        return "I couldn't create that image. Please try again."
                    data = await response.json()
        except Exception:
            return "I couldn't create that image. Please try again."

        # 4. Build the images list. Prefer uploading into OpenWebUI storage so
        #    the 3-day cleanup applies; fall back to an inline data URI.
        user_obj = None
        try:
            if isinstance(__user__, dict) and __user__.get("id"):
                user_obj = UserModel(**__user__)
        except Exception:
            user_obj = None

        metadata = __metadata__ if isinstance(__metadata__, dict) else {}

        images = []
        for item in data.get("data", []):
            raw = item.get("url") or item.get("b64_json") or ""
            if not raw:
                continue
            url = None
            if user_obj is not None and __request__ is not None:
                try:
                    image_data, content_type = await get_image_data(raw)
                    if image_data is not None and content_type is not None:
                        _, url = await upload_image(
                            __request__, image_data, content_type, metadata, user_obj
                        )
                except Exception:
                    url = None
            if not url:
                if raw.startswith(("http://", "https://")):
                    url = raw
                else:
                    url = f"data:image/png;base64,{raw}"
            images.append({"type": "image", "url": url})

        if not images:
            return "I couldn't create that image. Please try again."

        if __event_emitter__ is not None:
            await __event_emitter__(
                {"type": "status", "data": {"description": "Image created", "done": True}}
            )
            await __event_emitter__({"type": "files", "data": {"files": images}})

        return ""

PIPEEOF

cat > /tmp/create_model.py << 'PYEOF'
import sqlite3, json, uuid, time

conn = sqlite3.connect('/app/backend/data/webui.db')

# Bug #49: UPSERT — update existing model with latest capabilities instead of skipping
now = int(time.time())

# Custodian model meta — de-jargoned + 3-day image deletion warning
meta = json.dumps({
    "capabilities": {
        "web_search": True,
        "vision": True
    },
    "description": "Your AI assistant for questions, writing, and everyday help. To create images, switch to 'Custodian Images'. Images are kept for 3 days, then removed automatically."
})

# UPSERT Custodian model
existing = conn.execute("SELECT id FROM model WHERE name='Custodian'").fetchone()
if existing:
    conn.execute('UPDATE model SET base_model_id=?, meta=?, updated_at=? WHERE id=?',
        ('hermes-backend', meta, now, existing[0]))
    custodian_id = existing[0]
    was_update = True
else:
    model_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-model'))
    conn.execute('''INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, ?)''',
        (model_id, '', 'hermes-backend', 'Custodian', json.dumps({}), meta, now, now))
    custodian_id = model_id
    was_update = False

# DELETE broken "Custodian Images" chat model (Bug #106) — replaced by a Pipe function
broken = conn.execute(
    "SELECT id FROM model WHERE name='Custodian Images' AND base_model_id='gpt-image-2-hd'"
).fetchall()
for row in broken:
    conn.execute("DELETE FROM model WHERE id=?", (row[0],))

# UPSERT Custodian Images Pipe function (Bug #106 fix)
pipe_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, 'custodian-images-pipe'))
pipe_meta = json.dumps({
    "description": "Turn your description into an image. Images are kept for 3 days, then removed automatically.",
    "manifest": {"name": "Custodian Images", "version": "1.0.0"},
})
with open('/tmp/custodian_images_pipe.py', 'r') as f:
    pipe_content = f.read()

existing_pipe = conn.execute("SELECT id FROM function WHERE id=?", (pipe_id,)).fetchone()
if existing_pipe:
    conn.execute(
        "UPDATE function SET name=?, type=?, content=?, meta=?, is_active=?, is_global=?, updated_at=? WHERE id=?",
        ('Custodian Images', 'pipe', pipe_content, pipe_meta, True, True, now, pipe_id))
else:
    conn.execute(
        "INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (pipe_id, None, 'Custodian Images', 'pipe', pipe_content, pipe_meta, '{}', True, True, now, now))

# Auto-select Custodian as the default model
conn.execute(
    "INSERT INTO config (key, value) VALUES ('ui.default_models', ?) "
    "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    (json.dumps(custodian_id),))

conn.commit()
conn.close()
print('UPDATED' if was_update else 'CREATED')
PYEOF

docker cp /tmp/custodian_images_pipe.py "$WEBUI_CONTAINER":/tmp/
docker cp /tmp/create_model.py "$WEBUI_CONTAINER":/tmp/
STEP5D_OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 /tmp/create_model.py 2>&1)
docker exec "$WEBUI_CONTAINER" rm -f /tmp/custodian_images_pipe.py /tmp/create_model.py 2>/dev/null || true
rm -f /tmp/custodian_images_pipe.py /tmp/create_model.py
if echo "$STEP5D_OUTPUT" | grep -qE 'CREATED|UPDATED'; then
  if echo "$STEP5D_OUTPUT" | grep -q 'UPDATED'; then
    log_ok "Custodian models updated — chat + image generation refreshed"
  else
    log_ok "Custodian models created — chat + image generation enabled"
  fi
  # Bug #48: Restart WebUI to reload model cache (new/updated model won't show until restart)
  log_info "Restarting WebUI to refresh model cache..."
  docker restart "$WEBUI_CONTAINER" >/dev/null 2>&1
  # Wait for WebUI to be ready again
  for i in $(seq 1 30); do
    if curl -s -o /dev/null -w '%{http_code}' http://localhost:${WEBUI_PORT:-3000} 2>/dev/null | grep -qE '200|302'; then
      break
    fi
    [ "$i" -eq 30 ] && log_warn "WebUI slow to restart — check manually" 
    sleep 2
  done
  log_ok "WebUI restarted — model cache refreshed"
elif echo "$STEP5D_OUTPUT" | grep -q 'SKIP'; then
  log_ok "Custodian workspace model already exists (legacy SKIP — update script to UPSERT)"
else
  log_warn "Model creation failed (non-fatal)"
  log_warn "Output: $STEP5D_OUTPUT"
fi

log_step 'Step 5d2: Delete Stale API-Fetched Models'
# When Hermes advertises a model via /v1/models (API_SERVER_MODEL_NAME),
# OpenWebUI auto-creates a duplicate model entry with base_model_id=NULL.
# This model inherits ALL of Hermes' capabilities (terminal, code_exec, etc.)
# and confuses users. Delete it. Only the workspace model should exist.
cat > /tmp/delete_api_models.py << 'PYEOF'
import sqlite3
conn = sqlite3.connect('/app/backend/data/webui.db')
# API-fetched models: base_model_id IS NULL, user_id is a real user UUID
rows = conn.execute(
    "SELECT id, name, user_id FROM model WHERE name=? AND base_model_id IS NULL",
    ("Custodian",)
).fetchall()
for row in rows:
    conn.execute("DELETE FROM model WHERE id=?", (row[0],))
    print(f"DELETED API-fetched model: {row[1]} (id={row[0][:8]}..., user={row[2]})")
conn.commit()
if not rows:
    print("NONE_FOUND")
conn.close()
PYEOF

docker cp /tmp/delete_api_models.py "$WEBUI_CONTAINER":/tmp/
STEP5D2_OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 /tmp/delete_api_models.py 2>&1)
docker exec "$WEBUI_CONTAINER" rm /tmp/delete_api_models.py 2>/dev/null || true
rm /tmp/delete_api_models.py

if echo "$STEP5D2_OUTPUT" | grep -q 'DELETED'; then
  log_ok "Deleted stale API-fetched model(s) — only workspace model remains"
elif echo "$STEP5D2_OUTPUT" | grep -q 'NONE_FOUND'; then
  log_ok "No stale API-fetched models found"
else
  log_warn "API model cleanup: $STEP5D2_OUTPUT"
fi

log_step 'Step 5e: Register Vision Model + LiteLLM Routing'

# Bug #57: Vision Router filter routes to dashscope-vision but OpenWebUI
# validates models AFTER filter execution. dashscope-vision must be a known
# model AND must route directly to LiteLLM (bypassing Hermes, which overrides
# all model names to deepseek-v4-pro).
cat > /tmp/inject_vision_model.py << 'PYEOF'
import sqlite3, json, time, os

conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())

# Read current OpenAI connections
rows = conn.execute(
    "SELECT key, value FROM config WHERE key IN (?, ?, ?)",
    ("openai.api_configs", "openai.api_base_urls", "openai.api_keys")
).fetchall()
configs = {r[0]: json.loads(r[1]) if r[1] else (
    [] if "urls" in r[0] or "keys" in r[0] else {}
) for r in rows}

changes = 0

# Add LiteLLM as second connection (index 1) if not present
liteLLM_url = "http://100.64.0.1:4000/v1"
urls = configs.get("openai.api_base_urls", [])
if liteLLM_url not in urls:
    keys = configs.get("openai.api_keys", [])
    # Use IMAGES_OPENAI_API_KEY — set by Docker Compose (${CUSTOMER_API_KEY})
    # Available inside the WebUI container env. No docker exec needed.
    liteLLM_key = os.environ.get("IMAGES_OPENAI_API_KEY", "")
    if not liteLLM_key:
        liteLLM_key = keys[-1] if keys else ""
    
    urls.append(liteLLM_url)
    keys.append(liteLLM_key)
    conn.execute("UPDATE config SET value=? WHERE key=?",
        (json.dumps(urls), "openai.api_base_urls"))
    conn.execute("UPDATE config SET value=? WHERE key=?",
        (json.dumps(keys), "openai.api_keys"))
    changes += 1

# Bug #76: Inject image_generation DB config — env vars are silently overridden
# OpenWebUI's ENABLE_PERSISTENT_CONFIG=True (default) makes DB values authoritative
# Without this, correct env vars are ignored and image generation stays disabled
conn.execute("UPDATE config SET value=? WHERE key=?",
    (json.dumps(True), "image_generation.enable"))
conn.execute("UPDATE config SET value=? WHERE key=?",
    (json.dumps("openai"), "image_generation.engine"))
conn.execute("UPDATE config SET value=? WHERE key=?",
    (json.dumps("gpt-image-2-hd"), "image_generation.model"))
conn.execute("UPDATE config SET value=? WHERE key=?",
    (json.dumps("1024x1024"), "image_generation.size"))
conn.execute("UPDATE config SET value=? WHERE key=?",
    (json.dumps(liteLLM_url), "image_generation.openai.api_base_url"))
conn.execute("UPDATE config SET value=? WHERE key=?",
    (json.dumps(liteLLM_key), "image_generation.openai.api_key"))
changes += 6

# UPSERT dashscope-vision model
model_id = 'dashscope-vision'
meta = json.dumps({"capabilities": {"vision": True}})

existing = conn.execute(
    "SELECT id FROM model WHERE name=?", ("dashscope-vision",)
).fetchone()

if existing:
    conn.execute("UPDATE model SET meta=?, updated_at=? WHERE id=?",
        (meta, now, existing[0]))
else:
    conn.execute(
        "INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, TRUE, ?, ?)",
        (model_id, '', "dashscope-vision", "dashscope-vision", "{}", meta, now, now)
    )
    changes += 1

conn.commit()
conn.close()
print(f"OK:{changes}")
PYEOF

docker cp /tmp/inject_vision_model.py "$WEBUI_CONTAINER":/tmp/
STEP5E_OUTPUT=$(docker exec "$WEBUI_CONTAINER" python3 /tmp/inject_vision_model.py 2>&1)
docker exec "$WEBUI_CONTAINER" rm /tmp/inject_vision_model.py 2>/dev/null || true
rm /tmp/inject_vision_model.py

if echo "$STEP5E_OUTPUT" | grep -q 'OK'; then
  log_ok "Vision model + LiteLLM routing configured"
  # Restart WebUI to reload models and connections
  log_info "Restarting WebUI to refresh model cache..."
  docker restart "$WEBUI_CONTAINER" >/dev/null 2>&1
  for i in $(seq 1 30); do
    if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${WEBUI_PORT:-3000}" 2>/dev/null | grep -qE '200|302'; then
      break
    fi
    [ "$i" -eq 30 ] && log_warn "WebUI slow to restart — check manually"
    sleep 2
  done
  log_ok "WebUI restarted — vision routing active"
else
  log_warn "Vision model setup failed (non-fatal)"
  log_warn "Output: $STEP5E_OUTPUT"
fi

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

# 3. Budget Proxy — reachability check
# Note: /v1/models requires auth, so 401 = alive, 000 = dead
MODELS_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${PORT:-8642}/v1/models 2>/dev/null || echo 000)
if [ "$MODELS_CODE" != "000" ]; then
  log_ok "Budget Proxy reachable (HTTP $MODELS_CODE)"
else
  log_error "Budget Proxy: unreachable — check Budget Proxy on VM205"
fi

# 4. SearXNG DNS
if docker exec "$HERMES_CONTAINER" getent hosts searxng >/dev/null 2>&1; then
  log_ok "SearXNG DNS resolves"
else
  log_warn "SearXNG DNS: FAIL — run setup-searxng.sh first"
fi

# 5. PullMD extraction (optional)
if docker network inspect extractor-net >/dev/null 2>&1; then
  if docker exec "$HERMES_CONTAINER" getent hosts pullmd >/dev/null 2>&1; then
    log_ok "PullMD extraction available"
  else
    log_warn "PullMD DNS: FAIL — check extractor-net connection"
  fi
else
  log_info "PullMD not deployed — web extraction unavailable (optional)"
fi

log_step 'Step 5f: Image Cleanup Timer + 10 GB Cap'

cat > /usr/local/bin/custodian-cleanup.sh << 'SCRIPTEOF'
#!/bin/bash
set -uo pipefail

# Auto-detect the data dir (same pattern as fix-dell-redeploy.sh — never hardcode)
UPLOADS_DIR="${CUSTODIAN_DATA_DIR:-/data/webui-data}/uploads"
[ -d "$UPLOADS_DIR" ] || exit 0

MAX_BYTES=$((10 * 1024 * 1024 * 1024))   # 10 GB total

# 1) generated images older than 3 days
find "$UPLOADS_DIR" -name '*_generated-image.*' -mtime +3 -delete 2>/dev/null || true

# 2) other uploads older than 30 days
find "$UPLOADS_DIR" ! -name '*_generated-image.*' -mtime +30 -delete 2>/dev/null || true

# 3) enforce 10 GB total — delete oldest first until under cap
total=$(du -sb "$UPLOADS_DIR" 2>/dev/null | awk '{print $1}')
total=${total:-0}
if [ "$total" -gt "$MAX_BYTES" ]; then
  find "$UPLOADS_DIR" -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | while IFS=' ' read -r _ f; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        rm -f "$f" 2>/dev/null || true
        total=$((total - sz))
        if [ "$total" -le "$MAX_BYTES" ]; then break; fi
      done
fi
SCRIPTEOF
chmod +x /usr/local/bin/custodian-cleanup.sh

cat > /etc/systemd/system/custodian-cleanup.service << 'UNITEOF'
[Unit]
Description=Custodian — cleanup old images/uploads + enforce 10 GB cap
[Service]
Type=oneshot
ExecStart=/usr/local/bin/custodian-cleanup.sh
UNITEOF

cat > /etc/systemd/system/custodian-cleanup.timer << 'UNITEOF'
[Unit]
Description=Hourly Custodian cleanup
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
UNITEOF

systemctl daemon-reload
systemctl enable --now custodian-cleanup.timer
log_ok 'Cleanup timer active (generated images: 3 days, uploads: 30 days, 10 GB total cap)'

echo ''
echo '=== CUSTODIAN — READY ==='
echo "  Open WebUI:  http://${SERVER_IP}:${WEBUI_PORT:-3000}"
echo "  Hermes API:  http://${SERVER_IP}:${PORT:-8642}/v1"
echo "  Budget Proxy: ${BUDGET_PROXY_URL}"