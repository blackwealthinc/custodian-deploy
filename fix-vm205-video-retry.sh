#!/bin/bash
# ============================================================================
# Custodian — Fix video duplicate charges (Bug #141) on VM205
#
# Adds `num_retries: 0` to the custodian-video model so LiteLLM never re-submits
# a video job after a timeout/failure (each retry = a fresh $0.40 Veo charge).
# Idempotent: re-running is a no-op if num_retries is already 0.
#
# Usage (on VM205 as root):
#   curl -s https://raw.githubusercontent.com/blackwealthinc/custodian-deploy/main/fix-vm205-video-retry.sh | sudo -E bash
# ============================================================================
set -euo pipefail

CONFIG="/opt/litellm/litellm_config.yaml"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found"
    exit 1
fi

python3 << 'PYEOF'
import yaml
path = "/opt/litellm/litellm_config.yaml"
with open(path) as f:
    cfg = yaml.safe_load(f)

changed = False
found = False
for m in cfg.get("model_list", []):
    if m.get("model_name") == "custodian-video":
        found = True
        lp = m.setdefault("litellm_params", {})
        if lp.get("num_retries") != 0:
            lp["num_retries"] = 0
            changed = True
        break

if changed:
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
    print("OK: num_retries=0 set on custodian-video")
elif not found:
    print("WARN: custodian-video model not found in model_list — no change")
else:
    print("NO-CHANGE: num_retries already 0")
PYEOF

echo "Restarting LiteLLM…"
docker restart litellm-proxy >/dev/null 2>&1

echo "Waiting for LiteLLM…"
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/health/liveliness 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ]; then
        echo "OK: LiteLLM healthy"
        break
    fi
    [ "$i" -eq 60 ] && echo "WARN: LiteLLM slow to become healthy"
    sleep 3
done

echo "=== DONE ==="
echo "Verify:"
echo "  grep -A6 'custodian-video' $CONFIG | grep num_retries"
