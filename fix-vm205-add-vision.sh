#!/bin/bash
# fix-vm205-add-vision.sh
# Run ON VM205 as root.
# Adds dashscope-vision to the custodian virtual key in LiteLLM.

set -euo pipefail

echo "=== Fix VM205: Add dashscope-vision to Custodian Key ==="

# Find the custodian key
CUSTODIAN_KEY=$(docker exec litellm python3 -c "
import sqlite3
c = sqlite3.connect('/app/data/litellm.db')
rows = c.execute(\"SELECT models FROM verification_tokens WHERE key_alias='custodian'\").fetchall()
c.close()
if rows:
    import json
    print(json.dumps(rows[0][0]))
" 2>/dev/null)

if [ -z "$CUSTODIAN_KEY" ]; then
    echo "ERROR: Could not find custodian key in LiteLLM database"
    exit 1
fi

echo "Current models: $CUSTODIAN_KEY"

# Check if dashscope-vision is already present
if echo "$CUSTODIAN_KEY" | grep -q "dashscope-vision"; then
    echo "OK: dashscope-vision already in custodian key models"
    exit 0
fi

# Add dashscope-vision using LiteLLM's internal API (avoids curl auth issues)
echo "Adding dashscope-vision to custodian key..."
docker exec litellm python3 -c "
import sqlite3, json

c = sqlite3.connect('/app/data/litellm.db')
row = c.execute(\"SELECT token, models FROM verification_tokens WHERE key_alias='custodian'\").fetchone()
if not row:
    print('ERROR: custodian key not found')
    exit(1)

token, models_json = row
if isinstance(models_json, str):
    models = json.loads(models_json)
else:
    models = list(models_json)

if 'dashscope-vision' not in models:
    models.append('dashscope-vision')
    new_models = json.dumps(models)
    c.execute('UPDATE verification_tokens SET models=? WHERE key_alias=?', (new_models, 'custodian'))
    c.commit()
    print(f'UPDATED: {new_models}')
else:
    print('ALREADY_PRESENT')

c.close()
" 2>&1

# Verify
FINAL_MODELS=$(docker exec litellm python3 -c "
import sqlite3, json
c = sqlite3.connect('/app/data/litellm.db')
r = c.execute(\"SELECT models FROM verification_tokens WHERE key_alias='custodian'\").fetchone()
c.close()
print(json.dumps(r[0]))
" 2>/dev/null)

echo ""
echo "=== RESULT ==="
echo "Custodian key models: $FINAL_MODELS"

if echo "$FINAL_MODELS" | grep -q "dashscope-vision"; then
    echo "SUCCESS: dashscope-vision added to custodian key"
else
    echo "FAILED: dashscope-vision not in models list"
    exit 1
fi
