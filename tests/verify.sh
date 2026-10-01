#!/bin/sh
# Ground truth for realm-chatwoot: every figure this realm reports, re-asked of Chatwoot
# directly through its own API, and required to agree EXACTLY. Exits nonzero on any drift.
#
#   CHATWOOT=http://127.0.0.1:3100 CHATWOOT_ACCOUNT_ID=1 CHATWOOT_API_TOKEN=... \
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
#
# Three layers, each against the one before: Chatwoot itself, then a traversal through the
# business vocabulary's labels, then the saved views. A figure that reconciles at the view and
# not at the traversal means the view is compensating for something, and that is a finding.
set -e
CHATWOOT="${CHATWOOT:-http://127.0.0.1:3100}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
: "${CHATWOOT_API_TOKEN:?set CHATWOOT_API_TOKEN}"; : "${CHATWOOT_ACCOUNT_ID:?set CHATWOOT_ACCOUNT_ID}"
: "${AUTH:?set AUTH (user:pass)}"
API="$CHATWOOT/api/v1/accounts/$CHATWOOT_ACCOUNT_ID"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
py() { python3 -c "$1"; }
cw() { curl -s "$API$1" -H "api_access_token: $CHATWOOT_API_TOKEN"; }
kg() { curl -s -u "$AUTH" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys; print(json.dumps({"cypher": sys.argv[1]}))' "$1")"; }
view() { curl -s -u "$AUTH" -X POST "$APPLIANCE/api/v1/views/$1/invoke" -H 'Content-Type: application/json' -d "{\"args\":$2}"; }

echo "== L0: ground truth, from Chatwoot directly =="
count() { cw "/conversations?status=$1&assignee_type=all" | py 'import json,sys; print(json.load(sys.stdin)["data"]["meta"]["all_count"])'; }
ALL=$(count all); OPEN=$(count open); RESOLVED=$(count resolved)
# Walk every open page: the busiest account and the high-priority count are not in any meta.
TRUTH=$(py "
import json, urllib.request, collections
acct = collections.Counter(); high = 0; page = 1
while True:
    req = urllib.request.Request('$API/conversations?status=open&assignee_type=all&sort_by=created_at_asc&page=%d' % page,
                                 headers={'api_access_token': '$CHATWOOT_API_TOKEN'})
    rows = json.load(urllib.request.urlopen(req))['data']['payload']
    if not rows: break
    for c in rows:
        acct[c['custom_attributes'].get('account_key')] += 1
        high += c.get('priority') in ('urgent', 'high')
    page += 1
top = sorted(acct.items(), key=lambda kv: (-kv[1], kv[0]))[0]
print('%s:%d %d' % (top[0], top[1], high))")
TOP=${TRUTH% *}; HIGH=${TRUTH#* }
echo "  all=$ALL open=$OPEN resolved=$RESOLVED  busiest(account:open)=$TOP  open-high-or-urgent=$HIGH"

echo "== L1: the traversal, by the VOCABULARY's label, reconciles =="
N=$(kg "MATCH (d:ChatwootDesk {status:'all'})-[:HAS_CASE]->(c:SupportCase) RETURN count(c) AS n" | py 'import json,sys; print(json.load(sys.stdin)["rows"][0]["n"])')
check "cases, asked for as SupportCase" "$ALL" "$N"
N=$(kg "MATCH (d:ChatwootDesk {status:'open'})-[:HAS_CASE]->(c:SupportCase) RETURN count(c) AS n" | py 'import json,sys; print(json.load(sys.stdin)["rows"][0]["n"])')
check "open cases (status pushed to Chatwoot)" "$OPEN" "$N"
N=$(kg "MATCH (d:ChatwootDesk {status:'all'})-[:HAS_CASE]->(c:ChatwootConversation) RETURN count(c) AS n" | py 'import json,sys; print(json.load(sys.stdin)["rows"][0]["n"])')
check "the same cases, asked for as ChatwootConversation" "$ALL" "$N"

echo "== L2: the views reconcile =="
V=$(view ChatwootCaseCounts '{}')
check "view: open"     "$OPEN"     "$(echo "$V" | py 'import json,sys; print({r["status"]: r["cases"] for r in json.load(sys.stdin)["data"]}.get("open", 0))')"
check "view: resolved" "$RESOLVED" "$(echo "$V" | py 'import json,sys; print({r["status"]: r["cases"] for r in json.load(sys.stdin)["data"]}.get("resolved", 0))')"
V=$(view ChatwootOpenCases '{"limit": 1000}')
check "view: open case rows" "$OPEN" "$(echo "$V" | py 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"
check "view: open high-or-urgent" "$HIGH" "$(echo "$V" | py 'import json,sys; print(sum(r["priority"] in ("urgent","high") for r in json.load(sys.stdin)["data"]))')"
V=$(view ChatwootOpenCasesByAccount '{}')
check "view: busiest account" "$TOP" "$(echo "$V" | py 'import json,sys; r=json.load(sys.stdin)["data"][0]; print("%s:%d" % (r["account"], r["openCases"]))')"
check "view: open cases summed over accounts" "$OPEN" "$(echo "$V" | py 'import json,sys; print(sum(r["openCases"] for r in json.load(sys.stdin)["data"]))')"

echo "== the write verbs, against a scratch conversation =="
# Opt-in, because it writes to the Chatwoot it is pointed at, even though it cleans up after itself.
if [ "$VERIFY_WRITES" = 1 ]; then
  CHATWOOT="$CHATWOOT" CHATWOOT_ACCOUNT_ID="$CHATWOOT_ACCOUNT_ID" CHATWOOT_API_TOKEN="$CHATWOOT_API_TOKEN" \
    APPLIANCE="$APPLIANCE" AUTH="$AUTH" sh "$(dirname "$0")/verify-writes.sh" || fail=1
else
  echo "  SKIP: set VERIFY_WRITES=1 to exercise the write verbs"
fi

[ $fail = 0 ] && echo "ALL CHECKS PASS" || { echo "DRIFT FOUND"; exit 1; }
