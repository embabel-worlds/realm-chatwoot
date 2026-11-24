#!/bin/sh
# Ground truth for realm-chatwoot: every figure this realm reports, re-asked of Chatwoot
# directly through its own API, and required to agree EXACTLY. Exits nonzero on any drift.
#
#   CHATWOOT=http://127.0.0.1:3100 CHATWOOT_ACCOUNT_ID=1 CHATWOOT_API_TOKEN=... \
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
#
# Layers, each against the one before: Chatwoot itself, then a traversal through the business
# vocabulary's labels, then the saved views. A figure that reconciles at the view and not at the
# traversal means the view is compensating for something, and that is a finding. Then COST, which
# is a figure too: one company's cases must be read without the desk door and in no more calls than
# that company has pages (L3), a thread must come back whole (L4), and words in threads must be found
# by Chatwoot's search plus one read per case it found, never one read per case on the desk (L5).
set -e
# Either AUTH=user:pass or TOKEN=<appliance API key>. Both go to curl through a config file, so
# neither appears on a command line where `ps` would show it.
AUTHCFG=$(mktemp); trap 'rm -f "$AUTHCFG"' EXIT
if [ -n "${TOKEN:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTHCFG"
else printf 'user = "%s"\n' "${AUTH:?set AUTH (user:pass) or TOKEN}" > "$AUTHCFG"; fi
CHATWOOT="${CHATWOOT:-http://127.0.0.1:3100}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
: "${CHATWOOT_API_TOKEN:?set CHATWOOT_API_TOKEN}"; : "${CHATWOOT_ACCOUNT_ID:?set CHATWOOT_ACCOUNT_ID}"
API="$CHATWOOT/api/v1/accounts/$CHATWOOT_ACCOUNT_ID"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
# JSON goes to python through printf, never echo: /bin/sh on macOS has xpg_echo on, so `echo` turns
# the `\n` escapes in a message body into raw newlines and the JSON stops parsing.
py() { python3 -c "$1"; }
cw() { curl -s "$API$1" -H "api_access_token: $CHATWOOT_API_TOKEN"; }
kg() { curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys; print(json.dumps({"cypher": sys.argv[1]}))' "$1")"; }
view() { curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/$1/invoke" -H 'Content-Type: application/json' -d "{\"args\":$2}"; }

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
check "view: open"     "$OPEN"     "$(printf "%s\n" "$V" | py 'import json,sys; print({r["status"]: r["cases"] for r in json.load(sys.stdin)["data"]}.get("open", 0))')"
check "view: resolved" "$RESOLVED" "$(printf "%s\n" "$V" | py 'import json,sys; print({r["status"]: r["cases"] for r in json.load(sys.stdin)["data"]}.get("resolved", 0))')"
V=$(view ChatwootOpenCases '{"limit": 100000}')
check "view: open case rows" "$OPEN" "$(printf "%s\n" "$V" | py 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"
check "view: open high-or-urgent" "$HIGH" "$(printf "%s\n" "$V" | py 'import json,sys; print(sum(r["priority"] in ("urgent","high") for r in json.load(sys.stdin)["data"]))')"
V=$(view ChatwootOpenCasesByAccount '{"limit": 100000}')
check "view: busiest account" "$TOP" "$(printf "%s\n" "$V" | py 'import json,sys; r=json.load(sys.stdin)["data"][0]; print("%s:%d" % (r["account"], r["openCases"]))')"
check "view: open cases summed over accounts" "$OPEN" "$(printf "%s\n" "$V" | py 'import json,sys; print(sum(r["openCases"] for r in json.load(sys.stdin)["data"]))')"

echo "== L3: one company costs that company, not the desk =="
# The busiest open company is the hardest single-company case the desk has. Its ground truth comes
# from walking EVERY case through the plain list endpoint, which the account door does not use.
ACCT=${TOP%%:*}
ACCT_TRUTH=$(py "
import json, urllib.request
allc = opn = 0; ids = []; page = 1
while True:
    req = urllib.request.Request('$API/conversations?status=all&assignee_type=all&sort_by=created_at_asc&page=%d' % page,
                                 headers={'api_access_token': '$CHATWOOT_API_TOKEN'})
    rows = json.load(urllib.request.urlopen(req))['data']['payload']
    if not rows: break
    for c in rows:
        if c['custom_attributes'].get('account_key') == '$ACCT':
            allc += 1; opn += c['status'] == 'open'; ids.append(c['id'])
    page += 1
print(allc, opn, ids[-1])")
set -- $ACCT_TRUTH; ACCT_ALL=$1; ACCT_OPEN=$2; ACCT_CASE=$3
ACCT_PAGES=$(( (ACCT_ALL + 24) / 25 ))
echo "  $ACCT: all=$ACCT_ALL open=$ACCT_OPEN (at most $ACCT_PAGES calls for one company)"
# cost <json> -> "rows-or-n apiCalls deskCalls fetchedRecords". apiCalls is what THIS run asked the
# source, so a warm cache reads 0; fetchedRecords counts cache-served records too, so it is the
# figure that says how much of the desk a question touched whatever the cache holds.
cost() { py 'import json,sys
r = json.load(sys.stdin)
if r.get("reason"): print("REFUSED", r.get("reason"), r.get("error"), file=sys.stderr)
rows = r.get("rows") or []
n = rows[0].get("n") if rows and "n" in rows[0] else len(rows)
print(n, r.get("apiCalls", 0), sum(1 for c in r.get("apiCallLog", []) if c.startswith("chatwootConversationsByStatus")), r.get("fetchedRecords") or 0)'; }
set -- $(kg "MATCH (c:SupportCase) WHERE c.accountKey = '$ACCT' RETURN count(c) AS n" | cost)
check "one company's cases, by a bare accountKey pin" "$ACCT_ALL" "$1"
check "  ...read without touching the desk door" "0" "$3"
[ "$2" -le "$ACCT_PAGES" ] && echo "  ok   ...in $2 call(s)" || { echo "  FAIL ...in $2 calls, more than $ACCT_PAGES"; fail=1; }
[ "$4" -le "$ACCT_ALL" ] && echo "  ok   ...reading $4 case record(s), none of another company's" \
  || { echo "  FAIL ...reading $4 case records for a company with $ACCT_ALL"; fail=1; }
set -- $(kg "MATCH (c:SupportCase) WHERE c.accountKey = '$ACCT' AND c.status = 'open' RETURN count(c) AS n" | cost)
check "one company's OPEN cases (status pushed into the filter)" "$ACCT_OPEN" "$1"
check "  ...read without touching the desk door" "0" "$3"
V=$(view ChatwootCasesForCompany "{\"account\": \"$ACCT\"}")
check "view: ChatwootCasesForCompany rows" "$ACCT_ALL" "$(printf "%s\n" "$V" | py 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"
V=$(view ChatwootCasesForCompany "{\"account\": \"$ACCT\", \"status\": \"open\"}")
check "view: ChatwootCasesForCompany open rows" "$ACCT_OPEN" "$(printf "%s\n" "$V" | py 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"

echo "== L4: a thread is read whole =="
# Chatwoot answers a bare messages call with the latest 20 only; the realm asks for the range.
THREAD=$(cw "/conversations/$ACCT_CASE/messages?after=0&before=2147483648" | py 'import json,sys; print(len(json.load(sys.stdin)["payload"]))')
N=$(kg "MATCH (c:SupportCase) WHERE c.accountKey = '$ACCT' AND c.id = $ACCT_CASE MATCH (c)-[:HAS_MESSAGE]->(m:SupportMessage) RETURN count(m) AS n" | py 'import json,sys; print(json.load(sys.stdin)["rows"][0]["n"])')
check "messages on case $ACCT_CASE" "$THREAD" "$N"

echo "== L5: words in threads are found by Chatwoot's search, not by reading every thread =="
# TERM defaults to the longest word of that case's opening message; override with TERM=...
TERM_=${TERM_TEXT:-$(cw "/conversations/$ACCT_CASE/messages?after=0&before=2147483648" | py 'import json,sys,re
ms = [m for m in json.load(sys.stdin)["payload"] if m.get("message_type") in (0, 1) and m.get("content")]
print(max(re.findall(r"[A-Za-z]{6,}", ms[0]["content"]), key=len).lower())')}
FOUND=$(py "
import json, urllib.request, urllib.parse
ids = set(); page = 1
while True:
    req = urllib.request.Request('$API/conversations?assignee_type=all&sort_by=created_at_asc&q=%s&page=%d' % (urllib.parse.quote('$TERM_'), page),
                                 headers={'api_access_token': '$CHATWOOT_API_TOKEN'})
    rows = json.load(urllib.request.urlopen(req))['data']['payload']
    ids |= {c['id'] for c in rows}
    if len(rows) < 25: break
    page += 1
print(len(ids), page)")
set -- $FOUND; TEXT_CASES=$1; TEXT_PAGES=$2
echo "  '$TERM_': Chatwoot finds it in $TEXT_CASES conversations ($TEXT_PAGES search page(s))"
# The cost, read FRESH (`ai: {fresh: true}` on both edges): the view below would be served from what
# this reads, and a battery run twice inside the cache window would otherwise count 0 calls and pass
# without measuring anything.
set -- $(kg "MATCH (:ChatwootTextSearch {text: '$TERM_'})-[:HAS_CASE {ai: {fresh: true}}]->(c:SupportCase) MATCH (c)-[:HAS_MESSAGE {ai: {fresh: true}}]->(m:SupportMessage) WHERE toLower(m.body) CONTAINS '$TERM_' RETURN count(DISTINCT c) AS n" | cost)
check "cases whose threads say it, by the text door" "$TEXT_CASES" "$1"
[ "$2" -ge 1 ] && [ "$2" -le $((TEXT_PAGES + TEXT_CASES)) ] && echo "  ok   ...in $2 call(s), at most $TEXT_PAGES search + $TEXT_CASES threads" \
  || { echo "  FAIL ...in $2 calls, want 1 to $TEXT_PAGES search + $TEXT_CASES threads"; fail=1; }
check "  ...without touching the desk door" "0" "$3"
R=$(view ChatwootCasesMentioning "{\"text\": \"$TERM_\", \"limit\": 100000}")
check "view: ChatwootCasesMentioning cases" "$TEXT_CASES" "$(printf "%s\n" "$R" | py 'import json,sys; print(len({r["caseId"] for r in json.load(sys.stdin)["data"]}))')"
check "  ...every row's message contains the words" "0" "$(printf "%s\n" "$R" | py "import json,sys; print(sum('$TERM_' not in (r['message'] or '').lower() for r in json.load(sys.stdin)['data']))")"

echo "== the write verbs, against a scratch conversation =="
# Opt-in, because it writes to the Chatwoot it is pointed at, even though it cleans up after itself.
if [ "$VERIFY_WRITES" = 1 ]; then
  CHATWOOT="$CHATWOOT" CHATWOOT_ACCOUNT_ID="$CHATWOOT_ACCOUNT_ID" CHATWOOT_API_TOKEN="$CHATWOOT_API_TOKEN" \
    APPLIANCE="$APPLIANCE" AUTH="$AUTH" sh "$(dirname "$0")/verify-writes.sh" || fail=1
else
  echo "  SKIP: set VERIFY_WRITES=1 to exercise the write verbs"
fi

[ $fail = 0 ] && echo "ALL CHECKS PASS" || { echo "DRIFT FOUND"; exit 1; }
