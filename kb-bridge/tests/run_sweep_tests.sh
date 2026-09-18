set -u
sudo pkill -f mock_kb.py 2>/dev/null
sleep 1
sudo nohup /usr/bin/python3 /tmp/mock_kb.py > /tmp/mock_kb.log 2>&1 &
sleep 2
if curl -s -m 5 http://127.0.0.1:8556/__hits >/dev/null 2>&1; then
  echo "mock kill bill UP on 8556"
else
  echo "!! mock failed to start"; cat /tmp/mock_kb.log; exit 1
fi
echo
sudo /usr/bin/python3 /tmp/test_c.py
rc=$?
echo
echo "=== stopping mock ==="
sudo pkill -f mock_kb.py 2>/dev/null
sleep 1
curl -s -m 3 http://127.0.0.1:8556/__hits >/dev/null 2>&1 && echo "  !! mock still running" || echo "  mock stopped"
echo "test exit code: $rc"
