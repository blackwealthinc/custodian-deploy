#!/bin/bash
# fix-vm205-image-quality.sh
# Run ON VM205 (192.168.50.205).
# Bug #91: Removes quality:auto and size from gpt-image-2-hd config.
# gpt-image-2 does NOT support quality (only dall-e-3 does).
# OpenWebUI sends its own size param, so LiteLLM's duplicate breaks it.
#
# Source: https://platform.openai.com/docs/api-reference/images/create
#   "quality: This param is only supported for dall-e-3."

set -euo pipefail

CONFIG="/opt/litellm/litellm_config.yaml"

echo "=== Fix VM205: Remove quality/size from gpt-image-2-hd (Bug #91) ==="

# Backup
sudo cp "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
echo "Backed up config"

# Remove 'quality: auto' line from gpt-image-2-hd block
sudo sed -i '/model_name: gpt-image-2-hd/,/^[^- ]/{
  /quality:/d
  /^[[:space:]]*size:/d
}' "$CONFIG"

# Verify
echo ""
echo "=== gpt-image-2-hd block after fix ==="
sudo grep -A6 'model_name: gpt-image-2-hd' "$CONFIG"

# Restart LiteLLM to pick up config change
echo ""
echo "Restarting LiteLLM..."
sudo docker restart litellm-proxy >/dev/null 2>&1

# Wait for it
for i in $(seq 1 20); do
    if curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/v1/models 2>/dev/null | grep -qE '200|401'; then
        echo "LiteLLM restarted"
        break
    fi
    sleep 2
done

echo ""
echo "=== DONE ==="
echo "quality: auto and size lines removed from gpt-image-2-hd"
echo "Test: Use 'Custodian Images' model in WebUI"
