#!/bin/bash
# ============================================================================
# fix-dell-whitelabel.sh — White-label fix for the Dell (admin) instance
# ============================================================================
# Fixes:
#   Bug #117/#118 — raw provider model names leak into the customer dropdown
#   Bug #120      — "Arena Model" visible in the dropdown
#   Bug #123      — RAG_FILE_MAX_COUNT is a no-op (remove misleading config)
#
# Mechanism (verified against OpenWebUI v0.11.0 source on the Dell):
#   - The DB `model` table IS honored even with ENABLE_PERSISTENT_CONFIG=false
#     (only the `config` table is ignored). A row with base_model_id=NULL +
#     is_active=0 removes that model from the DROPDOWN only — it stays in
#     OPENAI_MODELS, so chat ("Custodian" -> hermes-backend) and vision
#     ("Dynamic Vision Router" -> dashscope-vision) keep working.
#   - Hiding is display-only (utils/models.py get_all_models -> models.remove).
#     Routing uses OPENAI_MODELS (openai.py), which is untouched.
#
# Usage (run on the Dell):
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/fix-dell-whitelabel.sh | sudo -E bash
# ============================================================================
set -euo pipefail

DATA_DIR="/data"
COMPOSE_FILE="$DATA_DIR/docker-compose.custodian-factory.yml"
WEBUI_DB="$DATA_DIR/webui-data/webui.db"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$DATA_DIR/backups/whitelabel-$STAMP"

log() { echo "[whitelabel] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: must run as root. Use: curl -s <this-script-url> | sudo -E bash"
    exit 1
fi

for f in "$COMPOSE_FILE" "$WEBUI_DB"; do
    [ -f "$f" ] || { log "ERROR: not found: $f"; exit 1; }
done

mkdir -p "$BACKUP_DIR"
cp -a "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose.custodian-factory.yml"
cp -a "$WEBUI_DB" "$BACKUP_DIR/webui.db"
[ -f "$DATA_DIR/.env" ] && cp -a "$DATA_DIR/.env" "$BACKUP_DIR/.env" || true
log "Backed up compose + DB + .env -> $BACKUP_DIR"

# ---------------------------------------------------------------------------
# STEP 1: Hide raw provider model names (DB override rows) — NO container
#         recreate needed. Safe and reversible.
# ---------------------------------------------------------------------------
log "Step 1: hiding raw model names from the dropdown (display-only)..."

python3 - "$WEBUI_DB" <<'PYEOF'
import sqlite3, sys, time
db = sys.argv[1]
conn = sqlite3.connect(db)
now = int(time.time())
raw_models = [
    "hermes-backend",     # connection 0 (Hermes gateway) raw name
    "deepseek-chat",      # connection 1 (LiteLLM budget proxy) raw names
    "deepseek-v4-pro",
    "deepseek-v4-flash",
    "gpt-image-2-hd",
    "dashscope-vision",   # still routed by the Dynamic Vision Router filter
    "custodian-video",
]
for m in raw_models:
    conn.execute(
        """
        INSERT INTO model (id, user_id, base_model_id, name, params, meta, created_at, updated_at, is_active)
        VALUES (?, '', NULL, ?, '{}', '{}', ?, ?, 0)
        ON CONFLICT(id) DO UPDATE SET base_model_id=NULL, is_active=0, updated_at=excluded.updated_at
        """,
        (m, m, now, now),
    )
conn.commit()
print(f"  Hidden {len(raw_models)} raw model names")
r = conn.execute("SELECT name, is_active, base_model_id FROM model WHERE name='Custodian'").fetchall()
print("  Custodian model intact:", r)
conn.close()
PYEOF

# ---------------------------------------------------------------------------
# STEP 2: Edit compose file — add Arena flag, remove count-limit no-op.
#         (File edit only; container recreate happens in Step 4.)
# ---------------------------------------------------------------------------
log "Step 2: editing compose file..."

if grep -q "ENABLE_EVALUATION_ARENA_MODELS" "$COMPOSE_FILE"; then
    log "  Arena flag already present"
else
    sed -i '/ENABLE_PERSISTENT_CONFIG=false/a\      - ENABLE_EVALUATION_ARENA_MODELS=false' "$COMPOSE_FILE"
    log "  Added ENABLE_EVALUATION_ARENA_MODELS=false"
fi

if grep -q "RAG_FILE_MAX_COUNT" "$COMPOSE_FILE"; then
    sed -i '/RAG_FILE_MAX_COUNT=10/d' "$COMPOSE_FILE"
    log "  Removed RAG_FILE_MAX_COUNT=10 (no-op)"
else
    log "  RAG_FILE_MAX_COUNT already absent"
fi

# ---------------------------------------------------------------------------
# STEP 3: Verify .env completeness before ANY container recreate.
#         This guards against Bug #114 (recreate without .env blanks API keys).
# ---------------------------------------------------------------------------
log "Step 3: verifying .env completeness before recreate..."

# Derive CUSTOMER_ID from the running webui container as a fallback.
CUSTOMER_ID_DETECTED="$(docker ps --format '{{.Names}}' | grep -E '\-webui$' | head -1 | sed 's/-webui$//' || true)"
log "  Detected CUSTOMER_ID from running container: ${CUSTOMER_ID_DETECTED:-<none>}"

MISSING=0
# Only the no-default API keys are hard blockers — these would BLANK on recreate
# if absent (Bug #114). CUSTOMER_ID has a fallback (derived from container name),
# and BUDGET_PROXY_URL/TZ/PORT have defaults in the compose file.
for k in API_SERVER_KEY CUSTOMER_API_KEY WEBUI_SECRET_KEY; do
    if ! grep -qE "^${k}=[^[:space:]]+" "$DATA_DIR/.env" 2>/dev/null; then
        log "  WARN: .env missing/empty $k"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    log "WARNING: .env appears incomplete. SKIPPING container recreate to avoid"
    log "         blanking API keys (Bug #114)."
    log "The model-hiding (Step 1) is already applied and active — that fixes the"
    log "main leak. Recreate manually once .env is confirmed complete, to pick up"
    log "the Arena flag + count-limit removal (cosmetic only)."
    exit 0
fi

# ---------------------------------------------------------------------------
# STEP 4: Recreate ONLY the openwebui container (hermes is untouched).
# ---------------------------------------------------------------------------
log "Step 4: recreating openwebui container..."
cd "$DATA_DIR"

# Derive the compose PROJECT name from the running container's label. The Dell's
# containers were launched with `docker compose -p admin` (project "admin"), NOT
# the default (directory name "data"). Without the correct project name, docker
# compose treats hermes as a NEW dependency and tries to CREATE it -> collides
# with the existing "admin-hermes" ("container name already in use").
WEBUI_NAME="${CUSTOMER_ID_DETECTED:-admin}-webui"
COMPOSE_PROJECT="$(docker inspect "$WEBUI_NAME" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
if [ -z "$COMPOSE_PROJECT" ]; then
    COMPOSE_PROJECT="${CUSTOMER_ID_DETECTED:-admin}"
    log "  WARN: no compose project label found — defaulting to $COMPOSE_PROJECT"
fi
log "  Compose project: $COMPOSE_PROJECT"

RECREATE_ENV=()
if [ -n "${CUSTOMER_ID_DETECTED:-}" ]; then
    # ALWAYS pass CUSTOMER_ID explicitly from the running container — this
    # overrides any stale/wrong CUSTOMER_ID in .env and guarantees the recreate
    # targets the SAME container (admin-webui) instead of the compose default.
    RECREATE_ENV=("CUSTOMER_ID=$CUSTOMER_ID_DETECTED")
    log "  Passing CUSTOMER_ID explicitly: $CUSTOMER_ID_DETECTED"
else
    log "  WARN: could not detect CUSTOMER_ID — recreate may fall back to compose default"
fi

if [ "${#RECREATE_ENV[@]}" -gt 0 ]; then
    env "${RECREATE_ENV[@]}" docker compose -p "$COMPOSE_PROJECT" -f docker-compose.custodian-factory.yml up -d openwebui
else
    docker compose -p "$COMPOSE_PROJECT" -f docker-compose.custodian-factory.yml up -d openwebui
fi

log "  Recreated. Waiting for container to start..."
sleep 15

docker ps --filter "name=$WEBUI_NAME" --format '{{.Names}} | {{.Status}}'

# ---------------------------------------------------------------------------
# STEP 5: Verify final state.
# ---------------------------------------------------------------------------
log "Step 5: verification — DB model table (Custodian visible + 7 raw hidden):"
python3 - "$WEBUI_DB" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for r in conn.execute("SELECT name, is_active, base_model_id FROM model ORDER BY name").fetchall():
    state = "HIDDEN (override)" if r[1] == 0 else "visible"
    print(f"  {r[0]:22} active={r[1]} base={r[2]} -> {state}")
conn.close()
PYEOF

log ""
log "DONE."
log "  - Raw provider names hidden from dropdown (Bugs #117/#118)"
log "  - Arena flag added to compose (Bug #120)"
log "  - RAG_FILE_MAX_COUNT removed (Bug #123)"
log "  - Backups at: $BACKUP_DIR"
log "  - Next: browser-verify the dropdown shows only 'Custodian' + pipes,"
log "    and that attaching an image still works (vision)."
