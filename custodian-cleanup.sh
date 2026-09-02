#!/bin/bash
set -uo pipefail

# Auto-detect the data dir (never hardcode — Bug #94/#96 lesson)
UPLOADS_DIR="${CUSTODIAN_DATA_DIR:-/data/webui-data}/uploads"
[ -d "$UPLOADS_DIR" ] || exit 0

MAX_BYTES=$((10 * 1024 * 1024 * 1024))   # 10 GB total

# 1) generated images older than 3 days
find "$UPLOADS_DIR" -name '*_generated-image.*' -mtime +3 -delete 2>/dev/null || true

# 1b) generated videos older than 3 days (same retention as images — Bug #143)
#     The video pipe uploads filename="video.mp4", stored as <uuid>_video.mp4.
find "$UPLOADS_DIR" -name '*_video.mp4' -mtime +3 -delete 2>/dev/null || true

# 2) other uploads older than 30 days (exclude generated images AND videos)
find "$UPLOADS_DIR" ! -name '*_generated-image.*' ! -name '*_video.mp4' -mtime +30 -delete 2>/dev/null || true

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
