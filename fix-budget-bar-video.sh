#!/usr/bin/env bash
# ============================================================================
# Custodian — Fix video download (emit type:"file") + add the automatic budget
# counter filter ("Custodian Budget Bar").
#
# Run on the Dell:
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/fix-budget-bar-video.sh | sudo -E bash
#
# Idempotent. No compose/env changes and no container restart required — OpenWebUI
# reads function content from the DB per request and invalidates its module cache
# on content change.
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main"
WEBUI_CONTAINER="admin-webui"
WEBUI_DATA="/data/webui-data"

log() { echo "[fix] $*"; }

# --- sanity: webui container must be running ---
if ! docker ps --format '{{.Names}}' | grep -qx "$WEBUI_CONTAINER"; then
  log "ERROR: container '$WEBUI_CONTAINER' is not running. Aborting."
  exit 1
fi

# ============================================================================
# Fix 1/2 — Custodian Video pipe: emit a downloadable "file" object
# ============================================================================
log "Fix 1/2: Custodian Video pipe (downloadable file object)"

curl -fsSL "$REPO/functions/custodian-video-pipe.py" -o "$WEBUI_DATA/custodian-video-pipe.py"
log "Fetched corrected video pipe source."

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
# Fix 2/2 — Custodian Budget Bar filter: auto-append live balance to replies
# ============================================================================
log "Fix 2/2: Custodian Budget Bar filter (automatic balance line)"

curl -fsSL "$REPO/functions/custodian-budget-filter.py" -o "$WEBUI_DATA/custodian-budget-filter.py"
log "Fetched budget filter source."

docker exec -i "$WEBUI_CONTAINER" python3 - <<'PYEOF'
import sqlite3, uuid, time, json
with open('/app/backend/data/custodian-budget-filter.py') as f:
    new_src = f.read()
meta_json = json.dumps({
    "description": "Automatically shows your live spend after every response.",
    "manifest": {"name": "Custodian Budget Bar", "version": "1.0.0"},
})
conn = sqlite3.connect('/app/backend/data/webui.db')
now = int(time.time())
row = conn.execute("SELECT id FROM function WHERE name='Custodian Budget Bar'").fetchone()
if row:
    conn.execute(
        "UPDATE function SET content=?, meta=?, is_active=1, is_global=1, updated_at=? WHERE name='Custodian Budget Bar'",
        (new_src, meta_json, now),
    )
    print('[fix] Budget filter already existed — updated. id=', row[0])
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

log ""
log "Done. No restart needed — functions are read from the DB per request."
log "Verify:"
log "  1. Send a chat message — a balance line should appear at the end of the reply."
log "  2. Generate a video — a clickable download link should appear, plus the balance line."
