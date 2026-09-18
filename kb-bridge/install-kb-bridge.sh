set -euo pipefail

BASE=/opt/kb-bridge
ENVF=$BASE/kb-bridge.env

echo "=== [1/7] layout ==="
sudo mkdir -p "$BASE"
sudo chown root:root "$BASE"
sudo chmod 755 "$BASE"

echo "=== [2/7] install code ==="
sudo install -m 755 -o root -g root /tmp/kb_bridge.py "$BASE/kb_bridge.py"
echo "  installed $BASE/kb_bridge.py ($(sudo wc -c < "$BASE/kb_bridge.py") bytes)"
sudo /usr/bin/python3 -m py_compile "$BASE/kb_bridge.py" && echo "  py_compile OK"

echo "=== [3/7] secrets ==="
# token: secret lives in the URL path (Kill Bill can send no auth header)
if sudo test -f "$ENVF" && sudo grep -q '^KB_PATH_TOKEN=.\+' "$ENVF"; then
  TOKEN=$(sudo sed -nE 's/^KB_PATH_TOKEN=(.+)$/\1/p' "$ENVF")
  echo "  reusing existing KB_PATH_TOKEN (fingerprint: ${TOKEN:0:6}...${TOKEN: -4})"
else
  TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  echo "  generated new KB_PATH_TOKEN (fingerprint: ${TOKEN:0:6}...${TOKEN: -4})"
fi

# master key came from the LiteLLM container config, written by the probe step
if sudo test -s /tmp/.kbmk; then
  MK=$(sudo cat /tmp/.kbmk)
  echo "  master key loaded from /tmp/.kbmk (len=${#MK})"
else
  echo "  !! /tmp/.kbmk missing -- cannot configure LiteLLM auth" >&2
  exit 1
fi

echo "=== [3/7] env file ($ENVF, mode 600) ==="
sudo tee "$ENVF" >/dev/null <<EOF
# Kill Bill -> LiteLLM bridge config
# generated $(date -Is)

KB_DB_PATH=$BASE/kb-bridge.db
KB_BIND=0.0.0.0
KB_PORT=8555
KB_PATH_TOKEN=$TOKEN

KB_LITELLM_URL=http://127.0.0.1:4000
KB_LITELLM_MASTER_KEY=$MK
# leave blank until the catalog/pricing is settled; monthly reset later
KB_BUDGET_DURATION=

# Kill Bill (fill in once the .104 tenant exists -> enables verification + sweep)
KB_KILLBILL_URL=
KB_KILLBILL_API_KEY=
KB_KILLBILL_API_SECRET=
KB_KILLBILL_USER=
KB_KILLBILL_PASSWORD=

# Fail-closed: never grant a budget on an unverified inbound event.
# Set to 0 ONLY for transport testing with no Kill Bill reachable.
KB_VERIFY=1

KB_WORKER_BATCH=10
KB_WORKER_POLL_SECONDS=2
KB_MAX_ATTEMPTS=8
KB_LOG_LEVEL=INFO
EOF
sudo chmod 600 "$ENVF"
sudo chown root:root "$ENVF"

echo "=== [4/7] systemd: receiver ==="
sudo tee /etc/systemd/system/kb-bridge-receiver.service >/dev/null <<'EOF'
[Unit]
Description=Kill Bill -> LiteLLM bridge (fast-ACK receiver)
Documentation=file:/opt/kb-bridge/kb_bridge.py
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/opt/kb-bridge/kb-bridge.env
ExecStart=/usr/bin/python3 /opt/kb-bridge/kb_bridge.py receiver
Restart=always
RestartSec=3
# kill only the receiver; Kill Bill gets a fast connection-refused, not a 15s hang
KillSignal=SIGTERM
TimeoutStopSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF

echo "=== [5/7] systemd: worker ==="
sudo tee /etc/systemd/system/kb-bridge-worker.service >/dev/null <<'EOF'
[Unit]
Description=Kill Bill -> LiteLLM bridge (queue worker)
Documentation=file:/opt/kb-bridge/kb_bridge.py
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=/opt/kb-bridge/kb-bridge.env
ExecStart=/usr/bin/python3 /opt/kb-bridge/kb_bridge.py worker
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
MemoryMax=192M

[Install]
WantedBy=multi-user.target
EOF

echo "=== [6/7] enable ==="
sudo systemctl daemon-reload
sudo systemctl enable kb-bridge-receiver.service kb-bridge-worker.service >/dev/null 2>&1
echo "  enabled"

echo "=== [7/7] init db ==="
sudo /usr/bin/python3 "$BASE/kb_bridge.py" init

echo
echo "=== sweep timer (reconciliation -- inert until Kill Bill creds are set) ==="
sudo tee /etc/systemd/system/kb-bridge-sweep.service >/dev/null <<'EOF'
[Unit]
Description=Kill Bill -> LiteLLM bridge (reconciliation sweep)
After=network-online.target docker.service
Wants=network-online.target kb-bridge-worker.service

[Service]
Type=oneshot
User=root
EnvironmentFile=/opt/kb-bridge/kb-bridge.env
ExecStart=/usr/bin/python3 /opt/kb-bridge/kb_bridge.py sweep --once
Nice=10
MemoryMax=128M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
EOF

sudo tee /etc/systemd/system/kb-bridge-sweep.timer >/dev/null <<'EOF'
[Unit]
Description=Run the Kill Bill reconciliation sweep every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=30s
Persistent=true
Unit=kb-bridge-sweep.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now kb-bridge-sweep.timer >/dev/null 2>&1
echo "  timer: $(systemctl is-enabled kb-bridge-sweep.timer)/$(systemctl is-active kb-bridge-sweep.timer)"

echo
# bare token, no prefix -- this is what goes in the URL path
printf '%s' "$TOKEN" | sudo tee "$BASE/.token" >/dev/null
sudo chmod 600 "$BASE/.token"
echo "done."
echo
echo "================================================================"
echo " REGISTER THIS CALLBACK URL IN KILL BILL (per tenant):"
echo "   http://192.168.50.205:8555/kb/events/$TOKEN"
echo " (bare token also stored at $BASE/.token, mode 600)"
echo "================================================================"
