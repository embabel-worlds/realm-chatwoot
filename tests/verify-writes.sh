#!/bin/sh
# relentless-testing for realm-chatwoot's WRITE verbs, each called through the appliance's gateway
# exactly as an agent's routine calls it and reconciled against Chatwoot directly.
#
# Against a scratch conversation, never a seeded one: Chatwoot cannot backdate, and a note on a
# seeded conversation would move its last activity to now, which is exactly what the quiet and
# silent arcs are measured by. The scratch contact is deleted at the end, and its conversation
# goes with it.
#
#   CHATWOOT=http://127.0.0.1:3100 CHATWOOT_ACCOUNT_ID=1 CHATWOOT_API_TOKEN=... \
#   APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify-writes.sh   (or APPLIANCE_TOKEN=...)
set -e
CHATWOOT="${CHATWOOT:-http://127.0.0.1:3100}"
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
: "${CHATWOOT_API_TOKEN:?set CHATWOOT_API_TOKEN}"; : "${CHATWOOT_ACCOUNT_ID:?set CHATWOOT_ACCOUNT_ID}"
if [ -n "$APPLIANCE_TOKEN" ]; then set -- -H "Authorization: Bearer $APPLIANCE_TOKEN"
else : "${AUTH:?set AUTH (user:pass) or APPLIANCE_TOKEN}"; set -- -u "$AUTH"; fi
API="$CHATWOOT/api/v1/accounts/$CHATWOOT_ACCOUNT_ID"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
cw() { # method path [json]
  curl -s -X "$1" "$API$2" -H "api_access_token: $CHATWOOT_API_TOKEN" -H 'Content-Type: application/json' ${3:+-d "$3"}
}
# Through the appliance, the way a routine calls it; the auth flags follow the operation and body.
verb() { op=$1; body=$2; shift 2
  curl -s -X POST "$APPLIANCE/api/v1/tools/chatwoot_$op" "$@" -H 'Content-Type: application/json' -d "$body"
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

TAG="verify-writes-$(date +%s)"
INBOX=$(cw GET /inboxes | field "d['payload'][0]['id']")
AGENT=$(cw GET /agents | field "d[0]['id']")
CONTACT=$(cw POST /contacts "{\"name\":\"$TAG\",\"email\":\"$TAG@example.invalid\"}" | field "d['payload']['contact']['id']")
CONV=$(cw POST /conversations "{\"inbox_id\":$INBOX,\"contact_id\":$CONTACT,\"source_id\":\"$TAG\"}" | field "d['id']")
trap 'cw DELETE /contacts/$CONTACT >/dev/null' EXIT
echo "== writes against scratch conversation $CONV (contact $CONTACT), tagged $TAG =="

echo "-- chatwootConversationAssign: into an agent's queue, then out again"
verb chatwootConversationAssign "{\"conversation_id\":$CONV,\"assignee_id\":$AGENT}" "$@" >/dev/null
ASSIGNED=$(cw GET /conversations/$CONV | field "(d['meta'].get('assignee') or {}).get('id')")
check "conversation is assigned to the agent" "$AGENT" "$ASSIGNED"
verb chatwootConversationAssign "{\"conversation_id\":$CONV,\"assignee_id\":0}" "$@" >/dev/null
UNASSIGNED=$(cw GET /conversations/$CONV | field "(d['meta'].get('assignee') or {}).get('id')")
check "assignee_id 0 unassigns it" "None" "$UNASSIGNED"

echo "-- chatwootMessageCreate: a private note, which the customer never sees"
MSG=$(verb chatwootMessageCreate "{\"conversation_id\":$CONV,\"content\":\"$TAG\",\"message_type\":\"outgoing\",\"private\":true}" "$@" | field "d['result']['id']")
ROW=$(cw GET /conversations/$CONV/messages)
check "note is in the conversation" "$TAG" "$(echo "$ROW" | field "[m['content'] for m in d['payload'] if m['id']==$MSG][0]")"
check "note is private" "True" "$(echo "$ROW" | field "[m['private'] for m in d['payload'] if m['id']==$MSG][0]")"
check "note is the team's (outgoing)" "1" "$(echo "$ROW" | field "[m['message_type'] for m in d['payload'] if m['id']==$MSG][0]")"

echo "-- the scratch contact goes, and its conversation with it"
cw DELETE /contacts/$CONTACT >/dev/null
trap - EXIT
sleep 2
GONE=$(curl -s -o /dev/null -w '%{http_code}' "$API/conversations/$CONV" -H "api_access_token: $CHATWOOT_API_TOKEN")
check "scratch conversation is gone" "404" "$GONE"

exit $fail
