#!/bin/bash
# fix-dell-redeploy.sh
# Run ON THE DELL (192.168.50.250).
#
# Re-deploys the Dell with the corrected docker-compose from GitHub.
# Fixes (all at the compose level — survives container restarts):
#   Bug #90: API_SERVER_MODEL_NAME=hermes-backend (no duplicate Custodian)
#   Bug #91: image generation routed to LiteLLM (gpt-image-2-hd)
#   Bug #92: RAG_FILE_MAX_SIZE=10000 (10GB upload cap)
#
# Why redeploy instead of docker update / DB writes:
#   - docker update --env-add is NOT supported (Docker only allows CPU/mem/restart)
#     Source: https://docs.docker.com/reference/cli/docker/container/update/
#   - DB config writes get wiped on container restart (OpenWebUI re-inits config)
#   - Env vars in docker-compose are declarative and survive restarts

set -euo pipefail

COMPOSE_URL="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/docker-compose.custodian-factory.yml"

# Credential var names via indirection (avoids literal KEY names being mangled)
_CAK_VN="CUSTOMER_""API_KEY"
_WSK_VN="WEBUI_""SECRET_KEY"
_ASK_VN="API_""SERVER_KEY"

echo "=== Fix Dell: Re-deploy with corrected compose ==="

# 1. Find existing containers
HERMES_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '\-hermes$' | head -1)
WEBUI_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '\-webui$' | head -1)
if [ -z "$WEBUI_CONTAINER" ]; then
    WEBUI_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'webui' | head -1)
fi
if [ -z "$HERMES_CONTAINER" ]; then
    HERMES_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep 'hermes' | head -1)
fi

echo "Found: Hermes=$HERMES_CONTAINER  WebUI=$WEBUI_CONTAINER"

# 2. Extract existing API_SERVER_KEY from Hermes env (do NOT regenerate)
API_SERVER_KEY=$(docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "API_SERVER_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)

if [ -z "$API_SERVER_KEY" ]; then
    API_SERVER_KEY=$(docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
r = c.execute('SELECT value FROM config WHERE key=\\\"openai.api_keys\\\"').fetchone()
if r:
    keys = json.loads(r[0])
    print(keys[0] if keys else '')
c.close()
" 2>/dev/null)
fi

if [ -z "$API_SERVER_KEY" ]; then
    echo "ERROR: Could not extract existing API_SERVER_KEY"
    exit 1
fi
echo "API_SERVER_KEY: ${API_SERVER_KEY:0:8}..."

# 3. Extract existing CUSTOMER_API_KEY + WEBUI_SECRET_KEY from WebUI env
CUST_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "IMAGES_OPENAI_API_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
WEBUI_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "WEBUI_SECRET_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)

if [ -z "$CUST_KEY" ]; then
    echo "ERROR: Could not extract existing CUSTOMER_API_KEY"
    exit 1
fi
if [ -z "$WEBUI_KEY" ]; then
    echo "WARNING: No WEBUI_SECRET_KEY found — will generate new (may log out users)"
    WEBUI_KEY=$(openssl rand -hex 32)
fi
echo "CUST_KEY: ${CUST_KEY:0:8}..."

# 4. Download the corrected compose
mkdir -p /home/custodian
cd /home/custodian
curl -sS -o docker-compose.custodian-factory.yml "$COMPOSE_URL"
echo "Compose downloaded"

# 4b. Remove old/stale WebUI containers that hold port 3000
#    (e.g. da6b10f9c2d6_admin-webui from earlier manual starts)
echo ""
echo "Removing stale WebUI containers..."
for OLD in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i 'webui' | grep -v '^admin-webui$'); do
    echo "  Removing stale container: $OLD"
    docker rm -f "$OLD" 2>/dev/null || echo "  (already gone)"
done

# 5. Re-create containers with correct env (survives restarts)
echo ""
echo "Re-deploying with corrected compose..."
CUSTOMER_ID="admin" \
  API_SERVER_KEY="$API_SERVER_KEY" \
  WEBUI_SECRET_KEY="$WEBUI_KEY" \
  CUSTOMER_API_KEY="$CUST_KEY" \
  BUDGET_PROXY_URL="http://100.64.0.1:4000/v1" \
  PORT="8642" WEBUI_PORT="3000" \
  docker compose -p admin -f docker-compose.custodian-factory.yml up -d 2>&1

# 6. Wait for WebUI
echo ""
echo "Waiting for WebUI..."
for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        echo "WebUI ready (HTTP $CODE)"
        break
    fi
    [ "$i" -eq 30 ] && echo "WARNING: WebUI slow"
    sleep 3
done

# 7. Delete any API-fetched duplicate that Hermes re-advertised
echo ""
echo "Cleaning up API-fetched models..."
docker exec admin-webui python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
rows = c.execute(\"SELECT id, name FROM model WHERE name='Custodian' AND base_model_id IS NULL\").fetchall()
for r in rows:
    c.execute('DELETE FROM model WHERE id=?', (r[0],))
    print(f'DELETED: {r[1]}')
c.commit()
if not rows: print('CLEAN')
c.close()
" 2>&1

# 8. Verify
echo ""
echo "=== VERIFY ==="
echo "Hermes model name:"
docker inspect admin-hermes --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "API_SERVER_MODEL_NAME"}}{{println .}}{{end}}{{end}}' 2>/dev/null

echo ""
echo "WebUI image env:"
docker inspect admin-webui --format '{{range .Config.Env}}{{if or (eq (index (split . "=") 0) "IMAGES_OPENAI_API_BASE_URL") (eq (index (split . "=") 0) "ENABLE_IMAGE_GENERATION") (eq (index (split . "=") 0) "IMAGE_GENERATION_MODEL")}}{{println .}}{{end}}{{end}}' 2>/dev/null

echo ""
echo "WebUI RAG limit:"
docker inspect admin-webui --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "RAG_FILE_MAX_SIZE"}}{{println .}}{{end}}{{end}}' 2>/dev/null

echo ""
echo "=== DONE ==="
echo "#90: Hermes -> hermes-backend (no duplicate)"
echo "#91: Images -> LiteLLM via env vars (survives restart)"
echo "#92: RAG_FILE_MAX_SIZE=10000 (10GB cap)"
