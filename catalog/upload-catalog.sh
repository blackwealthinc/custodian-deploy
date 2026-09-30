#!/usr/bin/env bash
# Upload a Kill Bill catalog with its effectiveDate STAMPED AT UPLOAD TIME.
#
# WHY THIS EXISTS
# ---------------
# Every Kill Bill tenant is created with an empty `DEFAULT` catalog dated
# `createdDate - 1 day` (POST /1.0/kb/tenants ends with createDefaultEmptyCatalog).
# Two subsystems then order the tenant's CATALOG rows by DIFFERENT keys:
#     getCurrentVersion()          -> orders by effectiveDate, picks the GREATEST
#     updateTenantLastKeyValue()   -> orders by record_id,     picks the HIGHEST
# `filterTemplateCatalog=true` hides the empty one on every billing path, but
# DefaultCatalogUserApi:195 (Simple Plan) passes false -- there the ordering matters.
#
# So the rule is: a real catalog must carry an effectiveDate LATER than the tenant's
# auto-created default. A file with a STATIC date can never satisfy that, because
# tenants are created continuously. `catalog/custodian-catalog.xml` is dated
# 2026-01-01 -- in the past -- so uploading it verbatim reproduces bug #167 on every
# new (reseller) tenant. This script stamps the date instead of trusting the file.
#
# SAFETY
# ------
# It does NOT trust HTTP 200. Kill Bill's catalog validator answers 200 *even when
# the catalog is invalid*; the errors are in the BODY. We assert an EMPTY
# `catalogValidationErrors` list AND parse the XML strictly before uploading.
#
# Usage:
#   ./upload-catalog.sh --kb-url http://HOST:8080 \
#       --api-key NAME --api-secret VALUE [--file catalog/...xml] [--dry-run]
#
# Env fallbacks: KB_URL, KB_KILLBILL_API_KEY, KB_KILLBILL_API_SECRET
set -euo pipefail

file="catalog/custodian-catalog.xml"
kb_url="${KB_URL:-http://192.168.50.104:8080}"
kb_user="$(printenv KB_KILLBILL_API_KEY 2>/dev/null || true)"
kb_pass="$(printenv KB_KILLBILL_API_SECRET 2>/dev/null || true)"
created_by="custodian-deploy"
effective=""
dry_run=0
admin_auth="${KB_ADMIN-admin:password}"

while [ $# -gt 0 ]; do
  case "$1" in
    --file)       file="$2"; shift 2 ;;
    --kb-url)     kb_url="$2"; shift 2 ;;
    --api-key)    kb_user="$2"; shift 2 ;;
    --api-secret) kb_pass="$2"; shift 2 ;;
    --created-by) created_by="$2"; shift 2 ;;
    --effective)  effective="$2"; shift 2 ;;   # override only for tests
    --dry-run)    dry_run=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$file" ] || { echo "FAIL: catalog file not found: $file" >&2; exit 1; }
[ -n "$kb_user" ] || { echo "FAIL: --api-key or KB_KILLBILL_API_KEY required" >&2; exit 1; }
[ -n "$kb_pass" ] || { echo "FAIL: --api-secret or KB_KILLBILL_API_SECRET required" >&2; exit 1; }

# Default: today at 00:00 UTC. Always later than `createdDate - 1 day` for any
# tenant created today or earlier, which is the whole point.
if [ -z "$effective" ]; then
  effective="$(date -u +%Y-%m-%dT00:00:00+00:00)"
fi

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

# --- 1. stamp the effectiveDate -------------------------------------------------
if ! grep -q "<effectiveDate>" "$file"; then
  echo "FAIL: no <effectiveDate> element in $file" >&2; exit 1
fi
# Replace ONLY the first occurrence (the catalog-level one, before <catalogName>).
python3 - "$file" "$tmp" "$effective" <<'PY'
import sys, re
src, dst, eff = sys.argv[1], sys.argv[2], sys.argv[3]
body = open(src, encoding="utf-8").read()
new, n = re.subn(r"<effectiveDate>[^<]*</effectiveDate>",
                 "<effectiveDate>%s</effectiveDate>" % eff, body, count=1)
if n != 1:
    sys.exit("FAIL: expected exactly 1 catalog-level <effectiveDate>, found %d" % n)
open(dst, "w", encoding="utf-8").write(new)
PY

old_date="$(grep -o '<effectiveDate>[^<]*' "$file" | head -1 | sed 's/.*>//')"
name="$(grep -o '<catalogName>[^<]*' "$tmp" | head -1 | sed 's/.*>//')"
echo "catalog    : $file"
echo "catalogName: $name"
echo "effective  : $old_date  ->  $effective   (stamped)"
[ "$dry_run" = "1" ] && echo "MODE       : DRY RUN (validate only, no upload)"

# --- 2. strict XML parse (a passing HTTP 200 is not a parse check) --------------
if ! python3 - "$tmp" <<'PY'
import sys, xml.parsers.expat
p = xml.parsers.expat.ParserCreate()
p.Parse(open(sys.argv[1], "rb").read(), True)
PY
then
  echo "FAIL: stamped XML is not well-formed" >&2
  exit 1
fi
echo "xml        : well-formed"

# --- 3. Kill Bill's own validator; read the BODY, not the status ----------------
resp="$(curl -s -u "$admin_auth" \
  -H "X-Killbill-ApiKey: $kb_user" -H "X-Killbill-ApiSecret: $kb_pass" \
  -H "X-Killbill-CreatedBy: $created_by" \
  -H "Content-Type: text/xml" -H "Accept: application/json" \
  -X POST --data-binary "@$tmp" "$kb_url/1.0/kb/catalog/xml/validate" || true)"

if ! printf '%s' "$resp" | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit('validator returned an EMPTY body (it answers 200 even when invalid)')
try:
    errs = json.loads(raw).get('catalogValidationErrors', None)
except Exception:
    sys.exit('validator body was not JSON: %r' % raw[:200])
if errs is None:
    sys.exit('no catalogValidationErrors key in body: %r' % raw[:200])
if errs:
    for e in errs:
        print('  INVALID:', e.get('errorDescription') or e, file=sys.stderr)
    sys.exit('catalog INVALID (%d error(s))' % len(errs))
"
then
  echo "FAIL: validation failed -- refusing to upload" >&2
  exit 1
fi
echo "validate   : catalogValidationErrors = [] (empty = valid)"

if [ "$dry_run" = "1" ]; then
  echo "DRY RUN OK -- nothing was uploaded."
  exit 0
fi

# --- 4. upload ---------------------------------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' -u "$admin_auth" \
  -H "X-Killbill-ApiKey: $kb_user" -H "X-Killbill-ApiSecret: $kb_pass" \
  -H "X-Killbill-CreatedBy: $created_by" \
  -H "Content-Type: text/xml" \
  -X POST --data-binary "@$tmp" "$kb_url/1.0/kb/catalog/xml")"

if [ "$code" != "201" ]; then
  echo "FAIL: upload returned HTTP $code (expected 201)" >&2
  exit 1
fi
echo "upload     : HTTP 201"

# --- 5. verify the ordering rule actually holds on THIS tenant ---------------
plans="$(curl -s -u "$admin_auth" \
  -H "X-Killbill-ApiKey: $kb_user" -H "X-Killbill-ApiSecret: $kb_pass" \
  -H "Accept: application/json" \
  "$kb_url/1.0/kb/catalog/availableBasePlans" || true)"

count="$(printf '%s' "$plans" | python3 -c "
import sys, json
try: print(len(json.load(sys.stdin)))
except Exception: print(0)
" 2>/dev/null || echo 0)"

if [ "$count" -lt 1 ]; then
  echo "FAIL: availableBasePlans is EMPTY -- the tenant is resolving an empty catalog." >&2
  echo "      The stamped date did not outrank the tenant's auto-created default." >&2
  exit 1
fi
echo "verify     : availableBasePlans -> $count plan(s)"
printf '%s' "$plans" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print('   -', p.get('name'), p.get('prices') or p.get('priceList') or '', p.get('billingPeriod') or '')
" 2>/dev/null || true

echo "OK: $name installed with effectiveDate $effective."
