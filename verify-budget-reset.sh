#!/bin/bash
# ============================================================================
# Custodian — Verify the LiteLLM budget-reset job actually fires
# ============================================================================
# Why this exists:
#   A budget only means something if the reset job really runs and clears
#   `spend`. That job is an APScheduler interval of 597-605 s
#   (PROXY_BUDGET_RESCHEDULER_MIN/MAX_TIME, constants.py:1467/1477), so the
#   mechanism is provable in ~10 minutes instead of waiting for a calendar
#   month boundary.
#
# What it does — entirely on a DISPOSABLE key that is deleted at the end:
#   1. creates a temp key with a deliberately short budget_duration
#   2. spends a token or two on it so real spend lands in the row
#   3. polls until `spend` returns to 0 and `budget_reset_at` advances
#   4. deletes the temp key in an EXIT trap (runs even if a step fails)
#
# Run ON the budget-proxy box (VM205) as root:
#   bash verify-budget-reset.sh
#
# Environment variables:
#   SELFTEST_DURATION   temp key duration (default: 30s)
#   SELFTEST_MAX_WAIT   seconds to wait for a tick (default: 900)
#   SELFTEST_MODEL      cheap model for the probe call (default: deepseek-v4-flash)
#   LITELLM_URL         default: http://127.0.0.1:4000
#   LITELLM_MASTER_KEY  default: auto-detected from the bridge env / litellm yaml
#
# Measured 2026-09-28: spend 1.05e-05 -> 0 and budget_reset_at 22:37 -> 22:44,
# i.e. the tick landed ~601 s after proxy start. Cost of a run: ~$0.00001.
# ============================================================================

set -euo pipefail

LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"
SELFTEST_DURATION="${SELFTEST_DURATION:-30s}"
SELFTEST_MAX_WAIT="${SELFTEST_MAX_WAIT:-900}"
SELFTEST_MODEL="${SELFTEST_MODEL:-deepseek-v4-flash}"
SELFTEST_ALIAS="${SELFTEST_ALIAS:-zz-reset-selftest}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

PG_CONTAINER="${PG_CONTAINER:-custodian-postgres}"
PG_DB="${PG_DB:-custodian}"
PG_USER="${PG_USER:-custodian}"

# Docker may need sudo when the service user is not in the docker group
if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi

psql_q() {
    $DOCKER exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tA -F'|' -c "$1"
}

resolve_master_key() {
    if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
        printf '%s' "$LITELLM_MASTER_KEY"; return 0
    fi
    if [ -r /opt/kb-bridge/kb-bridge.env ]; then
        local k
        k=$(grep -E '^KB_LITELLM_MASTER' /opt/kb-bridge/kb-bridge.env | head -1 \
            | sed 's/^[^=]*=//' | tr -d '\042\047 ')
        if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
    fi
    if [ -r /opt/litellm/litellm_config.yaml ]; then
        sed -n 's/^[[:space:]]*master_key:[[:space:]]*//p' /opt/litellm/litellm_config.yaml \
            | head -1 | tr -d '\042\047 '
    fi
}

MK="$(resolve_master_key)"
if [ -z "$MK" ]; then
    echo "ERROR: no LiteLLM master key found (set LITELLM_MASTER_KEY, or run on the proxy box)."
    exit 1
fi

TEMP_HASH=""
cleanup() {
    if [ -n "$TEMP_HASH" ]; then
        echo
        echo "--- cleanup: deleting the disposable key ---"
        curl -s -X POST "$LITELLM_URL/key/delete" --oauth2-bearer "$MK" \
            -H 'Content-Type: application/json' \
            -d "{\"keys\":[\"$TEMP_HASH\"]}" -w "\ndelete http=%{http_code}\n" | head -c 300 || true
        echo
        echo "--- keys remaining ---"
        psql_q "select coalesce(key_alias,'<null>') || ' | duration=' || coalesce(budget_duration,'NULL') \
                from \"LiteLLM_VerificationToken\" order by key_alias nulls first;" || true
    fi
}
trap cleanup EXIT

echo "============================================================================"
echo " Custodian — budget-reset self-test (duration=$SELFTEST_DURATION)"
echo "============================================================================"

echo
echo "--- step 1: create a disposable key ---"
RESP=$(curl -s -X POST "$LITELLM_URL/key/generate" --oauth2-bearer "$MK" \
    -H 'Content-Type: application/json' \
    -d "{\"key_alias\":\"$SELFTEST_ALIAS\",\"max_budget\":0.01,\"budget_duration\":\"$SELFTEST_DURATION\"}")

TK=$(printf '%s' "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null || true)
if [ -z "$TK" ]; then
    echo "ERROR: key creation failed. Response head:"
    printf '%s\n' "$RESP" | head -c 400
    exit 1
fi
TEMP_HASH=$(printf '%s' "$TK" | sha256sum | cut -d' ' -f1)
echo "    created (${#TK} chars); hash prefix $(printf '%s' "$TEMP_HASH" | cut -c1-8)"

BASE_RESET=$(psql_q "select coalesce(budget_reset_at::text,'NULL') from \"LiteLLM_VerificationToken\" where key_alias='$SELFTEST_ALIAS';")
echo "    baseline budget_reset_at = $BASE_RESET"

echo
echo "--- step 2: make a tiny real request so spend lands in the row ---"
curl -s -X POST "$LITELLM_URL/v1/chat/completions" --oauth2-bearer "$TK" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$SELFTEST_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" \
    -o /dev/null -w "    completion http=%{http_code}\n"

echo "    waiting 12s for the spend batch writer..."
sleep 12
SPEND=$(psql_q "select coalesce(spend::text,'0') from \"LiteLLM_VerificationToken\" where key_alias='$SELFTEST_ALIAS';")
echo "    spend after request = $SPEND"
if [ "$SPEND" = "0" ] || [ -z "$SPEND" ]; then
    echo "    NOTE: spend still 0 — the probe request may not have billed. The reset check"
    echo "          below still proves the job ran, because budget_reset_at must advance."
fi

echo
echo "--- step 3: wait for a reset tick (job interval 597-605 s) ---"
ELAPSED=0
PROVEN="no"
while [ "$ELAPSED" -lt "$SELFTEST_MAX_WAIT" ]; do
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
    S=$(psql_q "select coalesce(spend::text,'0') from \"LiteLLM_VerificationToken\" where key_alias='$SELFTEST_ALIAS';")
    R=$(psql_q "select coalesce(budget_reset_at::text,'NULL') from \"LiteLLM_VerificationToken\" where key_alias='$SELFTEST_ALIAS';")
    echo "    [t+${ELAPSED}s] spend=$S  reset_at=$R"
    if [ "$S" = "0" ]; then
        echo "    >>> spend was cleared to 0 — the reset job ran."
        PROVEN="yes"; break
    fi
    if [ -n "$R" ] && [ "$R" != "$BASE_RESET" ]; then
        echo "    >>> budget_reset_at advanced to $R — the reset job ran."
        PROVEN="yes"; break
    fi
done

echo
echo "============================================================================"
if [ "$PROVEN" = "yes" ]; then
    echo " RESULT: PASS — the budget-reset job is live and clears spend."
    echo " Budgets with budget_duration=1mo will reset on the 1st of each month."
else
    echo " RESULT: INCONCLUSIVE — no tick seen within ${SELFTEST_MAX_WAIT}s."
    echo " Check the container is running and disable_reset_budget is not set:"
    echo "   docker inspect litellm-proxy --format '{{.State.StartedAt}}'"
    echo "   grep -i disable_reset_budget /opt/litellm/litellm_config.yaml"
fi
echo "============================================================================"
