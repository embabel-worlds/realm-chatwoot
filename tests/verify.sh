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
# Whether an answer is the whole truth is the ENGINE's to say, and it says it beside the rows: a
# query's `error`, `reason` and `warnings` (each opening with its code), a view's `status`,
# `outcome` and `warnings`. A figure read past them reported a source that failed under load, or a
# page it capped, as drift in the realm. So every figure goes through short(): a refusal prints
# REFUSED and a short answer PARTIAL <figure>: <the engine's reason>, which no check expects.
SHORT_PY=$(cat <<'PY'
import json, sys
# Raw warning codes that mean rows or values may be missing (the engine's incompleteness kinds).
# Cost notes (FILTERED_IN_GRAPH, AGGREGATE_NOT_PUSHED, EMPTY_NOT_KEPT, PUSHDOWN_VALUE_UNMATCHED),
# FILTER_STARVED (an honest empty), STALE_COPY, FIELDS_WITHHELD and UNKNOWN_VIA leave every row in place.
SHORT_CODES = (
    "PARTIAL_RESULT", "PRODUCER_ERROR", "NEEDS_FILTER", "NEEDS_PRODUCER", "FILTER_REJECTED",
    "UNPUSHED_FILTER", "AMBIGUOUS_LABEL", "INCOMPLETE_TRAVERSAL", "INCOMPLETE_RANKING",
    "INCOMPLETE_AGGREGATE", "INCOMPLETE_INPUT", "MATERIALIZATION_FAILED", "REDUCTION_FAILED",
    "UNPARSEABLE_ANSWER", "TERMS_UNAVAILABLE", "COMPUTE_FAILED", "PROPERTY_NOT_STORED",
    "FOLLOW_CAPPED", "UNLINKED_CHILDREN", "RESOLUTION_DROPPED", "AGENTIC_DEGRADED",
    "SOURCE_UNANSWERED",
)
# The typed `reason` a query result carries when it is not a clean answer and not an honest empty.
SHORT_REASONS = ("UNBOUNDED", "PARTIAL_NOT_MATCHED", "UNPUSHED_FILTER", "DISCONNECTED",
                 "INTERNAL_ERROR", "WRITE_IN_PROGRESS", "KILLED", "TOO_EXPENSIVE")
# Public warning codes on a view envelope that mean the same.
SHORT_PUBLIC = ("PARTIAL", "REDUCTION_FAILED", "COMPUTE_FAILED", "PROPERTY_NOT_STORED",
                "AGENTIC_DEGRADED", "RATE_LIMITED", "SOURCE_UNAVAILABLE", "SOURCE_REJECTED",
                "INVALID_FILTER", "UNPUSHED_FILTER", "TOO_BROAD", "FETCH_CAPPED",
                "INDEX_UNAVAILABLE", "ARGUMENT_REFUSED")


def short(d, figure=None):
    tag = "PARTIAL" if figure is None else "PARTIAL %s" % (figure,)
    if not isinstance(d, dict):
        return "REFUSED: not an engine answer: " + str(d)[:160]
    if "outcome" in d or "status" in d:  # a view envelope
        err = d.get("error") or {}
        if d.get("status") != "SUCCEEDED":
            return "REFUSED: %s %s" % (d.get("status"), (err.get("code", "") + " " + err.get("message", "")).strip()[:160] if isinstance(err, dict) else str(err)[:160])
        ws = [w for w in d.get("warnings") or [] if isinstance(w, dict) and w.get("code") in SHORT_PUBLIC]
        if d.get("outcome") not in ("OK", "EMPTY") or ws:
            why = ws[0]["code"] + ": " + ws[0].get("message", "") if ws else "outcome " + str(d.get("outcome"))
            return "%s: %s" % (tag, why[:200])
        return None
    if d.get("error"):
        return "REFUSED: " + str(d["error"])[:160]
    if d.get("run"):
        return "%s: the run had not finished (%s)" % (tag, d["run"])
    ws = [w for w in d.get("warnings") or [] if isinstance(w, str) and w.split(":", 1)[0].strip() in SHORT_CODES]
    if ws:
        return "%s: %s" % (tag, ws[0][:200])
    if d.get("reason") in SHORT_REASONS:
        return "%s: reason %s" % (tag, d["reason"])
    return None
PY
)
# The figure in column n of a query answer on stdin.
n() { python3 -c "$SHORT_PY
d = json.load(sys.stdin); r = d.get('rows') or []
v = r[0].get('n') if r else 0
print(short(d, v) or v)"; }
# How many rows a view answered. Read from stdin: a whole book of rows passed as an argument is past
# the system's argument limit.
rows() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.load(sys.stdin); data = d.get('data') if isinstance(d, dict) else None
v = len(data) if isinstance(data, list) else 0
print(short(d, v) or v)"; }
# whole ANSWER SNIPPET: run SNIPPET over the parsed answer, as `d`, only when the engine says it is
# whole; otherwise print why it is not, in place of the figure.
whole() { printf '%s' "$1" | python3 -c "$SHORT_PY
d = json.load(sys.stdin); s = short(d)
if s: print(s); sys.exit(0)
$2"; }

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
N=$(kg "MATCH (d:ChatwootDesk {status:'all'})-[:HAS_CASE]->(c:SupportCase) RETURN count(c) AS n" | n)
check "cases, asked for as SupportCase" "$ALL" "$N"
N=$(kg "MATCH (d:ChatwootDesk {status:'open'})-[:HAS_CASE]->(c:SupportCase) RETURN count(c) AS n" | n)
check "open cases (status pushed to Chatwoot)" "$OPEN" "$N"
N=$(kg "MATCH (d:ChatwootDesk {status:'all'})-[:HAS_CASE]->(c:ChatwootConversation) RETURN count(c) AS n" | n)
check "the same cases, asked for as ChatwootConversation" "$ALL" "$N"

echo "== L2: the views reconcile =="
V=$(view ChatwootCaseCounts '{}')
check "view: open"     "$OPEN"     "$(whole "$V" 'import json,sys; print({r["status"]: r["cases"] for r in d["data"]}.get("open", 0))')"
check "view: resolved" "$RESOLVED" "$(whole "$V" 'import json,sys; print({r["status"]: r["cases"] for r in d["data"]}.get("resolved", 0))')"
V=$(view ChatwootOpenCases '{"limit": 100000}')
check "view: open case rows" "$OPEN" "$(rows "$V")"
check "view: open high-or-urgent" "$HIGH" "$(whole "$V" 'import json,sys; print(sum(r["priority"] in ("urgent","high") for r in d["data"]))')"
V=$(view ChatwootOpenCasesByAccount '{"limit": 100000}')
check "view: busiest account" "$TOP" "$(whole "$V" 'import json,sys; r=d["data"][0]; print("%s:%d" % (r["account"], r["openCases"]))')"
check "view: open cases summed over accounts" "$OPEN" "$(whole "$V" 'import json,sys; print(sum(r["openCases"] for r in d["data"]))')"

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
# A figure the engine marks short or refused is no figure: its first field is then the single word
# PARTIAL or REFUSED, which no check expects, and the engine's reason goes to stderr beside it.
cost() { python3 -c "$SHORT_PY
r = json.load(sys.stdin)
rows = r.get('rows') or []
n = rows[0].get('n') if rows and 'n' in rows[0] else len(rows)
s = short(r, n)
if s: print('  ' + s, file=sys.stderr); n = s.split()[0].rstrip(':')
print(n, r.get('apiCalls', 0), sum(1 for c in r.get('apiCallLog', []) if c.startswith('chatwootConversationsByStatus')), r.get('fetchedRecords') or 0)"; }
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
check "view: ChatwootCasesForCompany rows" "$ACCT_ALL" "$(rows "$V")"
V=$(view ChatwootCasesForCompany "{\"account\": \"$ACCT\", \"status\": \"open\"}")
check "view: ChatwootCasesForCompany open rows" "$ACCT_OPEN" "$(rows "$V")"

echo "== L4: a thread is read whole =="
# Chatwoot answers a bare messages call with the latest 20 only; the realm asks for the range.
THREAD=$(cw "/conversations/$ACCT_CASE/messages?after=0&before=2147483648" | py 'import json,sys; print(len(json.load(sys.stdin)["payload"]))')
N=$(kg "MATCH (c:SupportCase) WHERE c.accountKey = '$ACCT' AND c.id = $ACCT_CASE MATCH (c)-[:HAS_MESSAGE]->(m:SupportMessage) RETURN count(m) AS n" | n)
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
check "view: ChatwootCasesMentioning cases" "$TEXT_CASES" "$(whole "$R" 'import json,sys; print(len({r["caseId"] for r in d["data"]}))')"
check "  ...every row's message contains the words" "0" "$(whole "$R" "import json,sys; print(sum('$TERM_' not in (r['message'] or '').lower() for r in d['data']))")"

echo "== L6: a window on a business day is read from Chatwoot, not from the whole desk =="
# Ground truth from the PLAIN LIST, which the desk door no longer uses, walked whole: every status
# and the three business days of each case. Each bound is a day the desk holds (its median), so the
# day itself is the case a strict comparison must leave out.
DAYS=$(py "
import json, urllib.request
rows = []; page = 1
while True:
    req = urllib.request.Request('$API/conversations?status=all&assignee_type=all&sort_by=created_at_asc&page=%d' % page,
                                 headers={'api_access_token': '$CHATWOOT_API_TOKEN'})
    got = json.load(urllib.request.urlopen(req))['data']['payload']
    if not got: break
    rows += got; page += 1
def days(k): return sorted(c['custom_attributes'].get(k) for c in rows if c['custom_attributes'].get(k))
o, u, cl = days('opened_on'), days('updated_on'), days('closed_on')
d, e, f = o[len(o) // 2], u[len(u) // 2], cl[len(cl) // 2]
print(d, sum(x > d for x in o), sum(x < d for x in o), sum(x >= d for x in o),
      e, sum(c['status'] == 'open' and (c['custom_attributes'].get('updated_on') or '') > e for c in rows),
      f, sum(x > f for x in cl), sum(x < f for x in cl),
      sum(c['status'] == 'resolved' and (c['custom_attributes'].get('closed_on') or '') > f for c in rows))")
set -- $DAYS; DAY=$1; OPENED_AFTER=$2; OPENED_BEFORE=$3; OPENED_SINCE=$4; UDAY=$5; OPEN_UPDATED_AFTER=$6; CDAY=$7; CLOSED_AFTER=$8; CLOSED_BEFORE=$9; RESOLVED_CLOSED_AFTER=${10}
echo "  opened after $DAY: $OPENED_AFTER, before: $OPENED_BEFORE, on or after: $OPENED_SINCE; open and updated after $UDAY: $OPEN_UPDATED_AFTER; closed after $CDAY: $CLOSED_AFTER, before: $CLOSED_BEFORE"
WINDOW_PAGES=$(( (OPENED_AFTER + 24) / 25 ))
# Read FRESH, so the cost is this question's and not a cache's.
DESK="(:ChatwootDesk {status:'all'})-[:HAS_CASE {ai: {fresh: true}}]->(c:SupportCase)"
# The cases themselves, not a count, so the walk is what is measured: a count is one call (below).
set -- $(kg "MATCH $DESK WHERE c.openedOn > '$DAY' RETURN size(collect(DISTINCT c.id)) AS n" | cost)
check "cases opened after $DAY" "$OPENED_AFTER" "$1"
[ "$3" -le "$WINDOW_PAGES" ] && echo "  ok   ...in $3 desk call(s), the window's pages, not the desk's" \
  || { echo "  FAIL ...in $3 desk calls, more than the window's $WINDOW_PAGES pages"; fail=1; }
set -- $(kg "MATCH $DESK WHERE c.openedOn > '$DAY' RETURN count(c) AS n" | cost)
check "how many opened after $DAY" "$OPENED_AFTER" "$1"
[ "$3" -le "$WINDOW_PAGES" ] && echo "  ok   ...in $3 desk call(s)" \
  || { echo "  FAIL ...in $3 desk calls, more than the window's $WINDOW_PAGES pages"; fail=1; }
set -- $(kg "MATCH $DESK WHERE c.openedOn < '$DAY' RETURN count(c) AS n" | cost)
check "how many opened before $DAY" "$OPENED_BEFORE" "$1"
# Inclusive: Chatwoot has only the strict comparison, so the host sends `> the day before`
# (granularity: day). The bound day is the median, so it must be counted.
set -- $(kg "MATCH $DESK WHERE c.openedOn >= '$DAY' RETURN size(collect(DISTINCT c.id)) AS n" | cost)
check "cases opened on or after $DAY, the bound day included" "$OPENED_SINCE" "$1"
SINCE_PAGES=$(( (OPENED_SINCE + 24) / 25 ))
[ "$3" -le "$SINCE_PAGES" ] && echo "  ok   ...in $3 desk call(s), the window's pages" \
  || { echo "  FAIL ...in $3 desk calls, more than the window's $SINCE_PAGES pages"; fail=1; }
set -- $(kg "MATCH (:ChatwootDesk {status:'open'})-[:HAS_CASE {ai: {fresh: true}}]->(c:SupportCase) WHERE c.updatedOn > '$UDAY' RETURN count(c) AS n" | cost)
check "open cases updated after $UDAY" "$OPEN_UPDATED_AFTER" "$1"
set -- $(kg "MATCH $DESK WHERE c.closedOn > '$CDAY' RETURN count(c) AS n" | cost)
check "cases closed after $CDAY" "$CLOSED_AFTER" "$1"
set -- $(kg "MATCH $DESK WHERE c.closedOn < '$CDAY' RETURN count(c) AS n" | cost)
check "cases closed before $CDAY (a case never closed is in neither)" "$CLOSED_BEFORE" "$1"
# A status on the case is applied in the graph on this door (see the producer), so this must still
# count every resolved case, not a pushed total.
set -- $(kg "MATCH $DESK WHERE c.status = 'resolved' RETURN count(c) AS n" | cost)
check "resolved cases, a status on the case over the whole desk" "$RESOLVED" "$1"
# A window and a status together: the window is sent, the status applied to what comes back.
set -- $(kg "MATCH $DESK WHERE c.closedOn > '$CDAY' AND c.status = 'resolved' RETURN count(c) AS n" | cost)
check "resolved cases closed after $CDAY" "$RESOLVED_CLOSED_AFTER" "$1"

echo "== the write verbs, against a scratch conversation =="
# Opt-in, because it writes to the Chatwoot it is pointed at, even though it cleans up after itself.
if [ "$VERIFY_WRITES" = 1 ]; then
  CHATWOOT="$CHATWOOT" CHATWOOT_ACCOUNT_ID="$CHATWOOT_ACCOUNT_ID" CHATWOOT_API_TOKEN="$CHATWOOT_API_TOKEN" \
    APPLIANCE="$APPLIANCE" AUTH="$AUTH" sh "$(dirname "$0")/verify-writes.sh" || fail=1
else
  echo "  SKIP: set VERIFY_WRITES=1 to exercise the write verbs"
fi

[ $fail = 0 ] && echo "ALL CHECKS PASS" || { echo "DRIFT FOUND"; exit 1; }
