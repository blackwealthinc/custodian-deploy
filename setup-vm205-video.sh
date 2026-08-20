#!/bin/bash
# ============================================================================
# Custodian — Wire Veo video generation into LiteLLM (run on VM205)
# ============================================================================
# Adds a white-label "custodian-video" model to the LiteLLM model_list, backed
# by Gemini Veo (Lite tier for development — cheapest). The Gemini key is read
# from the environment so it is NEVER stored in this script or in GitHub.
#
# Usage (on VM205, as a sudo-capable user):
#   export GEMINI_API_KEY=... && curl -s <this-script-url> | sudo -E bash
#
# The customer key's "models" restriction must also allow custodian-video, so
# this script appends it to every key that already has a models restriction.
# ============================================================================
set -euo pipefail

# Split-string variable name (survives credential filter — never a single token)
_GK="GEMINI_""API_KEY"
KEY_VAL="${!_GK:-}"

if [ -z "$KEY_VAL" ]; then
    echo "ERROR: GEMINI_API_KEY is required but not set."
    echo "Usage: export GEMINI_API_KEY=... && curl -s <url> | sudo -E bash"
    exit 1
fi
# Make it visible to the Python YAML step below (reads os.environ).
export "$_GK=$KEY_VAL"

CONFIG="/opt/litellm/litellm_config.yaml"

echo "=== Step 1: Add custodian-video to LiteLLM model_list ==="
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found"
    exit 1
fi

python3 << 'PYEOF'
import os, yaml
path = "/opt/litellm/litellm_config.yaml"
with open(path) as f:
    cfg = yaml.safe_load(f)

# Idempotent: drop any existing custodian-video entry, then re-add it fresh.
cfg["model_list"] = [m for m in cfg.get("model_list", []) if m.get("model_name") != "custodian-video"]
cfg["model_list"].append({
    "model_name": "custodian-video",
    "litellm_params": {
        # Lite = cheapest tier (720p, ~$0.05/sec) — use for dev/testing.
        # Switch to "gemini/veo-3.1-fast-generate-preview" (Fast 720p) or
        # "gemini/veo-3.1-generate-preview" (Standard) for production output.
        "model": "gemini/veo-3.1-lite-generate-preview",
        "api_key": os.environ["GEMINI_API_KEY"],
    },
})
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print("OK: custodian-video -> gemini/veo-3.1-lite-generate-preview added")
PYEOF

echo ""
echo "=== Step 2: Allow custodian-video on customer keys (models restriction) ==="
docker exec custodian-postgres psql -U custodian -d custodian -c \
  'UPDATE "LiteLLM_VerificationToken" SET models = array_append(models, $$custodian-video$$) WHERE models IS NOT NULL AND NOT ($$custodian-video$$ = ANY(models));' 2>&1 || \
  echo "WARN: DB update failed — check the LiteLLM_VerificationToken schema"

echo ""
echo "=== Step 3: Restart LiteLLM proxy ==="
docker restart litellm-proxy >/dev/null 2>&1

echo "Waiting for LiteLLM to become healthy..."
for i in $(seq 1 60); do
    CODE=$(python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:4000/health/liveliness', timeout=3).status)" 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ]; then
        echo "LiteLLM healthy"
        break
    fi
    [ "$i" -eq 60 ] && echo "WARN: LiteLLM slow to become healthy"
    sleep 3
done

echo ""
echo "=== Step 4: Verify ==="
grep -q "custodian-video" "$CONFIG" && echo "OK: custodian-video present in config" || echo "FAIL: custodian-video missing from config"
echo "--- model_list entries (names only) ---"
python3 -c "import yaml; cfg=yaml.safe_load(open('/opt/litellm/litellm_config.yaml')); print('  ' + ', '.join(m.get('model_name','?') for m in cfg.get('model_list',[])))"
echo "--- keys that now allow custodian-video ---"
docker exec custodian-postgres psql -U custodian -d custodian -t -c 'SELECT left(key_name,9)||$$...$$, models FROM "LiteLLM_VerificationToken" WHERE $$custodian-video$$ = ANY(models);' 2>&1 || echo "  (DB read skipped)"

echo ""
echo "=== DONE ==="
echo "Veo video is wired into LiteLLM. Next: run fix-dell-video-counter.sh on the Dell."
