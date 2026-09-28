#!/bin/bash
# ============================================================================
# Custodian — Fix orphaned key budgets (the budget that never resets)
# ============================================================================
# What this does:
#   Finds LiteLLM virtual keys that carry a direct `max_budget` but have NO
#   `budget_id` and NO `budget_duration`. Such a key is a "one-time budget":
#   LiteLLM's reset job only selects rows whose budget_reset_at is in the past,
#   and a NULL budget_duration means budget_reset_at is never set — so spend
#   accumulates until it hits the ceiling and the key stays blocked PERMANENTLY.
#
#   A key WITH a budget_id is NOT affected: it inherits that budget object's
#   schedule, and its own budget_duration stays NULL by design.
#
# Verified against the LiteLLM version we run (v1.95.0), from source:
#   key_management_endpoints.py:1925-1935  /key/update writes budget_duration AND budget_reset_at
#   key_management_endpoints.py:942-946    keys linked to a budget inherit its schedule
#   litellm/proxy/utils.py:5299            _hash_token_if_needed accepts a stored sha256 hash
#   duration_parser.py                     "1mo" snaps to the 1st of the month ("30d" is equivalent)
#   constants.py:1467,1477                 reset job interval = 597-605 s (PROXY_BUDGET_RESCHEDULER_*)
#
# Run ON the budget-proxy box (VM205) as root:
#   bash fix-orphan-budget-durations.sh                             # dry run (default)
#   bash fix-orphan-budget-durations.sh --apply                     # repair every orphan
#   bash fix-orphan-budget-durations.sh --clear --only <alias>      # revert (requires --only)
#
#   --only <alias[,alias]>  restrict the run to specific key aliases. REQUIRED for
#                           --clear, so a revert can never touch unrelated live keys.
#
# Environment variables:
#   KB_BUDGET_DURATION   duration to apply (default: 1mo — calendar-monthly, resets on the 1st)
#   LITELLM_URL          LiteLLM base URL (default: http://127.0.0.1:4000)
#   LITELLM_MASTER_KEY   master key (default: auto-detected from the bridge env / litellm yaml)
#   PG_CONTAINER/PG_DB/PG_USER  defaults: custodian-postgres / custodian / custodian
#
# Reversible: --clear --only <alias> sets both fields back to NULL for those aliases only.
# ============================================================================

set -euo pipefail

LITELLM_URL="${LITELLM_URL:-http://127.0.0.1:4000}"
DURATION="${KB_BUDGET_DURATION:-1mo}"

PG_CONTAINER="${PG_CONTAINER:-custodian-postgres}"
PG_DB="${PG_DB:-custodian}"
PG_USER="${PG_USER:-custodian}"

# Docker may need sudo when the service user is not in the docker group
if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi

usage() {
    cat <<'USAGE'
usage: fix-orphan-budget-durations.sh [dry-run | --apply | --clear --only <alias[,alias]>]
       --only <alias[,alias]>  limit to specific key aliases (required for --clear)
USAGE
}

MODE="dry-run"
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        dry-run)   MODE="dry-run" ;;
        --apply)   MODE="apply" ;;
        --clear)   MODE="clear" ;;
        --only)    shift; ONLY="${1:-}" ;;
        --only=*)  ONLY="${1#--only=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1"; usage; exit 2 ;;
    esac
    shift
done

# A bulk revert is dangerous: it would also clear keys we deliberately repaired.
# Requiring --only makes the revert exact and auditable.
if [ "$MODE" = "clear" ] && [ -z "$ONLY" ]; then
    echo "ERROR: --clear requires --only <alias[,alias]>."
    echo "       Refusing a bulk revert — it would also clear unrelated live keys."
    echo "       Example: $0 --clear --only zz-orphan-test"
    exit 2
fi

psql_q() {
    $DOCKER exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -tA -F'|' -c "$1"
}

# --- master key: never printed, only measured -------------------------------
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
        return 0
    fi
    return 0
}

# --- build the selection predicate -----------------------------------------
WHERE="budget_id is null and max_budget is not null"
case "$MODE" in
    dry-run|apply) WHERE="$WHERE and budget_duration is null" ;;
    clear)         WHERE="$WHERE and budget_duration is not null and budget_duration = '$DURATION'" ;;
esac
if [ -n "$ONLY" ]; then
    IN="$(printf '%s' "$ONLY" | sed "s/,/','/g")"
    WHERE="$WHERE and key_alias in ('$IN')"
fi

echo "============================================================================"
echo " Custodian — orphaned key budget repair"
echo "   mode=$MODE   duration=$DURATION   only=${ONLY:-<all>}"
echo "============================================================================"

echo
echo "--- every key with a direct max_budget ---"
psql_q "select coalesce(key_alias,'<null>') || ' | budget_id=' || coalesce(budget_id,'NONE') \
        || ' | max_budget=' || coalesce(max_budget::text,'-') \
        || ' | duration=' || coalesce(budget_duration,'NULL') \
        || ' | reset_at=' || coalesce(budget_reset_at::text,'NULL') \
        || ' | spend=' || coalesce(spend::text,'-')
        from \"LiteLLM_VerificationToken\"
        where max_budget is not null
        order by key_alias nulls first;"

TARGETS=$(psql_q "select coalesce(key_alias,'<null>') || '~' || token || '~' || coalesce(max_budget::text,'0') \
        from \"LiteLLM_VerificationToken\" \
        where $WHERE \
        order by key_alias nulls first;")

COUNT=$(printf '%s\n' "$TARGETS" | grep -c . || true)

echo
echo "--- selected keys: $COUNT ---"
if [ "$COUNT" -eq 0 ]; then
    case "$MODE" in
        dry-run|apply) echo "Nothing to do. Every direct-budget key already has a reset schedule." ;;
        clear)         echo "Nothing to revert for the requested alias(es) at duration=$DURATION." ;;
    esac
    exit 0
fi

printf '%s\n' "$TARGETS" | while IFS='~' read -r alias token mb; do
    [ -z "${token:-}" ] && continue
    echo "    alias=${alias}  max_budget=${mb}"
done

if [ "$MODE" = "dry-run" ]; then
    echo
    echo "DRY RUN — nothing changed. Re-run with --apply to set duration=$DURATION."
    exit 0
fi

MK="$(resolve_master_key)"
if [ -z "$MK" ]; then
    echo "ERROR: no LiteLLM master key found (set LITELLM_MASTER_KEY, or run on the proxy box)."
    exit 1
fi
echo
echo "master key loaded (${#MK} chars)"

if [ "$MODE" = "clear" ]; then
    BODY_FIELD="null"
    ACTION="clearing duration (revert to a one-time budget)"
else
    BODY_FIELD="\"$DURATION\""
    ACTION="applying duration=$DURATION"
fi

echo "--- $ACTION ---"
printf '%s\n' "$TARGETS" | while IFS='~' read -r alias token mb; do
    [ -z "${token:-}" ] && continue
    code=$(curl -s -o /tmp/.orphan_update.json -w '%{http_code}' \
        -X POST "$LITELLM_URL/key/update" \
        --oauth2-bearer "$MK" \
        -H 'Content-Type: application/json' \
        -d "{\"key\":\"$token\",\"budget_duration\":$BODY_FIELD}")
    echo "    alias=${alias}  http=$code"
    rm -f /tmp/.orphan_update.json
done

echo
echo "--- after (re-read from the database, not from the API response) ---"
psql_q "select coalesce(key_alias,'<null>') || ' | budget_id=' || coalesce(budget_id,'NONE') \
        || ' | max_budget=' || coalesce(max_budget::text,'-') \
        || ' | duration=' || coalesce(budget_duration,'NULL') \
        || ' | reset_at=' || coalesce(budget_reset_at::text,'NULL')
        from \"LiteLLM_VerificationToken\"
        where max_budget is not null
        order by key_alias nulls first;"

if [ "$MODE" = "apply" ]; then
    echo
    echo "Done. A reset job tick (every 597-605 s) will now clear these keys' spend at the"
    echo "1st of the month. Prove the mechanism end-to-end with verify-budget-reset.sh."
fi
