#!/usr/bin/env bash
# ============================================================================
# Custodian — Fix video inline playback (Bug #140) + live budget (Bug #139)
#
# Two parts, in dependency order:
#
#   PART 1 — Upgrade OpenWebUI v0.11.0 -> v0.11.1.  v0.11.1 adds the
#            DEFAULT_INTERFACE_SETTINGS env var (verified in config.py:
#            `ui.default_interface_settings`), which lets us flip
#            `iframeSandboxAllowSameOrigin` on system-wide.  That makes the chat
#            embed iframe same-origin, so the <video> player can load the
#            authenticated file URL /api/v1/files/{id}/content (cookie is sent).
#            Without this the video would 401 in the sandboxed iframe.
#
#   PART 2 — Redeploy the Custodian Video / Custodian Images pipes and the
#            budget filter from this repo (embeds video player, live budget line
#            in the pipe reply, and a guard so the filter doesn't double-append).
#
# Usage (run ON THE DELL as root):
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/fix-dell-video-budget.sh | sudo -E bash
#
# Idempotent: re-running upgrades to the pinned version (no-op if already there)
# and re-applies the function sources (content-hash cached by OpenWebUI).
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main"
GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo "[fix] $*"; }
log_ok()  { echo -e "  ${GREEN}OK:${NC} $1"; }
log_err() { echo -e "  ${RED}ERROR:${NC} $1"; }
step()    { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# ════════════════════════════════════════════════════════════════════════════
# PART 1 — Upgrade OpenWebUI v0.11.0 -> v0.11.1
# ════════════════════════════════════════════════════════════════════════════
step "Part 1/2: Upgrade OpenWebUI to v0.11.1"

# 1a. Locate the running containers.
WEBUI_CONTAINER=$(docker ps --format '{{.Names}}' | grep '\-webui$' | head -1)
HERMES_CONTAINER=$(docker ps --format '{{.Names}}' | grep '\-hermes$' | head -1)
if [ -z "$WEBUI_CONTAINER" ]; then
    log_err "no running *-webui container found"
    exit 1
fi
log "WebUI container: $WEBUI_CONTAINER"
log "Hermes container: ${HERMES_CONTAINER:-<none found>}"

# 1b. Extract the live env values so `docker compose up -d` resolves the compose
#     placeholders to the SAME values already running (prevents recreating the
#     hermes container with emptied keys, and preserves sessions/auth).
API_SERVER_KEY=$(docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "API_SERVER_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$API_SERVER_KEY" ]; then
    API_SERVER_KEY=$(docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/backend/data/webui.db')
r = c.execute('SELECT value FROM config WHERE key=?', ('openai.api_keys',)).fetchone()
if r:
    keys = json.loads(r[0])
    print(keys[0] if keys else '')
c.close()
" 2>/dev/null)
fi
if [ -z "$API_SERVER_KEY" ]; then log_err "no API_SERVER_KEY"; exit 1; fi

CUST_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "IMAGES_OPENAI_API_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$CUST_KEY" ]; then
    CUST_KEY=$(docker inspect "$HERMES_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "OPENAI_API_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
fi
if [ -z "$CUST_KEY" ]; then log_err "no CUSTOMER_API_KEY"; exit 1; fi

WEBUI_KEY=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "WEBUI_SECRET_KEY"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
if [ -z "$WEBUI_KEY" ]; then log_err "no WEBUI_SECRET_KEY"; exit 1; fi

BUDGET_PROXY_URL=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "IMAGES_OPENAI_API_BASE_URL"}}{{index (split . "=") 1}}{{end}}{{end}}' 2>/dev/null)
BUDGET_PROXY_URL="${BUDGET_PROXY_URL:-http://100.64.0.1:4000/v1}"
log "Budget proxy: $BUDGET_PROXY_URL"

# 1c. Auto-detect the real data directory (relative compose volume ./webui-data
#     resolves from the directory that holds the compose file).
CUSTODIAN_HOME=""
for DIR in /data /home/custodian /home/admin /opt/custodian; do
    if [ -f "$DIR/webui-data/webui.db" ]; then
        CUSTODIAN_HOME="$DIR"; break
    fi
done
if [ -z "$CUSTODIAN_HOME" ]; then
    log_err "could not find an existing webui.db under /data, /home/custodian, /home/admin, /opt/custodian"
    exit 1
fi
log "Data directory: $CUSTODIAN_HOME"

# 1d. Download the updated compose (v0.11.1 + DEFAULT_INTERFACE_SETTINGS) and
#     recreate only what changed (webui image+env; hermes is untouched).
cd "$CUSTODIAN_HOME"
curl -fsSL -o docker-compose.custodian-factory.yml "$REPO/docker-compose.custodian-factory.yml"
log "Compose updated at $CUSTODIAN_HOME/docker-compose.custodian-factory.yml"

CUSTOMER_ID="admin" \
  API_SERVER_KEY="$API_SERVER_KEY" \
  WEBUI_SECRET_KEY="$WEBUI_KEY" \
  CUSTOMER_API_KEY="$CUST_KEY" \
  BUDGET_PROXY_URL="$BUDGET_PROXY_URL" \
  PORT="8642" WEBUI_PORT="3000" \
  docker compose -p admin -f docker-compose.custodian-factory.yml up -d 2>&1

# 1e. Wait for the WebUI to come back up.
log "Waiting for WebUI…"
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
        log_ok "WebUI ready ($CODE)"
        break
    fi
    sleep 3
done

# Confirm the version actually landed.
IMG=$(docker inspect "$WEBUI_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || echo "MISSING")
log "WebUI image now: $IMG"
ENV_OK=$(docker inspect "$WEBUI_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -c 'DEFAULT_INTERFACE_SETTINGS' || echo 0)
log "DEFAULT_INTERFACE_SETTINGS present: $ENV_OK"

# ════════════════════════════════════════════════════════════════════════════
# PART 2 — Redeploy the updated functions
# ════════════════════════════════════════════════════════════════════════════
step "Part 2/2: Deploy updated pipes + budget filter"

fetch_into() {
  local src="$1" dst="$2"
  curl -fsSL "$REPO/$src" | docker exec -i "$WEBUI_CONTAINER" sh -c "cat > $dst"
}

# 2a. Custodian Video pipe — embeds <video> player + live budget line.
log "Custodian Video pipe…"
fetch_into "functions/custodian-video-pipe.py" "/app/backend/data/custodian-video-pipe.py"
docker exec -i "$WEBUI_CONTAINER" python3 - <<'PYEOF'
import sqlite3
with open('/app/backend/data/custodian-video-pipe.py') as f:
    new_src = f.read()
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.execute("UPDATE function SET content=? WHERE name='Custodian Video'", (new_src,))
conn.commit()
print('[fix] Video pipe updated:', cur.rowcount, 'row(s)')
conn.close()
PYEOF

# 2b. Custodian Images pipe — live budget line.
log "Custodian Images pipe…"
fetch_into "functions/custodian-images-pipe.py" "/app/backend/data/custodian-images-pipe.py"
docker exec -i "$WEBUI_CONTAINER" python3 - <<'PYEOF'
import sqlite3
with open('/app/backend/data/custodian-images-pipe.py') as f:
    new_src = f.read()
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.execute("UPDATE function SET content=? WHERE name='Custodian Images'", (new_src,))
conn.commit()
print('[fix] Image pipe updated:', cur.rowcount, 'row(s)')
conn.close()
PYEOF

# 2c. Custodian Budget Bar filter — guard against double-append (v1.2.0).
log "Custodian Budget Bar filter…"
fetch_into "functions/custodian-budget-filter.py" "/app/backend/data/custodian-budget-filter.py"
docker exec -i "$WEBUI_CONTAINER" python3 - <<'PYEOF'
import sqlite3, uuid, time, json
with open('/app/backend/data/custodian-budget-filter.py') as f:
    new_src = f.read()
meta_json = json.dumps({
    "description": "Automatically shows your live spend after every response.",
    "manifest": {"name": "Custodian Budget Bar", "version": "1.3.0"},
})
conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())
row = conn.execute("SELECT id FROM function WHERE name='Custodian Budget Bar'").fetchone()
if row:
    conn.execute(
        "UPDATE function SET content=?, meta=?, is_active=1, is_global=1, updated_at=? WHERE name='Custodian Budget Bar'",
        (new_src, meta_json, now),
    )
    print('[fix] Budget filter updated. id=', row[0])
else:
    fid = str(uuid.uuid4())
    conn.execute(
        "INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, created_at, updated_at) "
        "VALUES (?, NULL, ?, 'filter', ?, ?, '{}', 1, 1, ?, ?)",
        (fid, 'Custodian Budget Bar', new_src, meta_json, now, now),
    )
    print('[fix] Budget filter inserted. id=', fid)
conn.commit()
conn.close()
PYEOF

# ════════════════════════════════════════════════════════════════════════════
# Verify
# ════════════════════════════════════════════════════════════════════════════
step "Verify"
docker exec "$WEBUI_CONTAINER" python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
for r in c.execute(\"SELECT name, type, is_active, is_global FROM function WHERE name LIKE 'Custodian%'\").fetchall():
    print(f'  {r[0]:24s} type={r[1]:6s} active={r[2]} global={r[3]}')
c.close()
"

echo ""
log "Done."
log ""
log "⚠️  IMPORTANT — hard-refresh your browser NOW:  Ctrl+Shift+R (or Cmd+Shift+R on Mac)."
log "   This clears the cached frontend from the previous OpenWebUI version."
log "   Skipping this can cause a black screen / infinite-refresh loop."
log ""
log "Verify in the browser:"
log "  1. Generate a video — it should play INLINE (video player), with the balance line under it."
log "  2. Generate an image — image + balance line."
log "  3. Send a chat message — balance line should appear live at the end (Bug #139)."
log "If the video shows a blank box, confirm DEFAULT_INTERFACE_SETTINGS is present (printed above) and hard-refresh the chat."
