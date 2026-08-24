#!/usr/bin/env bash
# ============================================================================
# Custodian — Fix Bug #131 (video download) + Bug #132 (default model)
#
# Run on the Dell:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/fix-dell-video-default-model.sh | sudo -E bash
#
# Idempotent + reversible (compose is backed up before edit).
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main"
WEBUI_CONTAINER="admin-webui"
WEBUI_DATA="/data/webui-data"
COMPOSE_FILE="/data/docker-compose.custodian-factory.yml"

log() { echo "[fix] $*"; }

# --- sanity: webui container must be running ---
if ! docker ps --format '{{.Names}}' | grep -qx "$WEBUI_CONTAINER"; then
  log "ERROR: container '$WEBUI_CONTAINER' is not running. Aborting."
  exit 1
fi

# ============================================================================
# Fix 1/2 — Custodian Video pipe (Bug #131): persist + return a real File
# ============================================================================
log "Fix 1/2: Custodian Video pipe (Bug #131)"

curl -fsSL "$REPO/functions/custodian-video-pipe.py" -o "$WEBUI_DATA/custodian-video-pipe.py"
log "Fetched corrected pipe source."

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

# ============================================================================
# Fix 2/2 — Default model (Bug #132): DEFAULT_MODELS env + recreate
# ============================================================================
log "Fix 2/2: Default model (Bug #132)"

if [ ! -f "$COMPOSE_FILE" ]; then
  log "ERROR: compose file '$COMPOSE_FILE' not found. Aborting Fix 2."
  exit 1
fi

PROJECT="$(docker inspect "$WEBUI_CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
case "$PROJECT" in
  "" | "<no value>") PROJECT="admin" ;;
esac
log "Compose project: $PROJECT"

cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
log "Backed up compose."

COMPOSE_FILE="$COMPOSE_FILE" python3 - <<'PYEOF'
import os
path = os.environ["COMPOSE_FILE"]
lines = open(path).read().splitlines()

if any("DEFAULT_MODELS=hermes-backend" in line for line in lines):
    print("[fix] DEFAULT_MODELS already present — skipping edit.")
else:
    out = []
    inserted = False
    for line in lines:
        out.append(line)
        if not inserted and "ENABLE_PERSISTENT_CONFIG=false" in line:
            indent = line[: len(line) - len(line.lstrip())]
            out.append(f"{indent}# Default model (Bug #132) — DB is ignored under ENABLE_PERSISTENT_CONFIG=false")
            out.append(f"{indent}- DEFAULT_MODELS=hermes-backend")
            inserted = True
    if not inserted:
        print("[fix] ERROR: ENABLE_PERSISTENT_CONFIG=false line not found.")
        raise SystemExit(1)
    open(path, "w").write("\n".join(out) + "\n")
    print("[fix] Added DEFAULT_MODELS=hermes-backend.")
PYEOF

log "Recreating webui container ('$WEBUI_CONTAINER') to apply the new env var..."
cd /data
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --no-deps openwebui

log "Waiting for the container to come back up..."
sleep 8
docker ps --format '{{.Names}}\t{{.Status}}' | grep "$WEBUI_CONTAINER" || true

log ""
log "Done."
log "Verify:"
log "  1. Model dropdown should now default to 'Custodian' (not blank / first model)."
log "  2. Generate a video — it should now show a clickable download link."
