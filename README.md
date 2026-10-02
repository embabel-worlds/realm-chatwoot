# realm-chatwoot

Chatwoot, spoken to through its own application API, as an Embabel realm — and as the
**support** slot of the business vocabulary. A conversation here *is* a `SupportCase`; a message
*is* a `SupportMessage`. The node carries both labels:

```cypher
MATCH (d:ChatwootDesk {status:'open'})-[:HAS_CASE]->(c:SupportCase)
WHERE c.priority IN ['urgent', 'high']
RETURN c.accountKey, c.subject, c.requesterName, c.replyCount
```

Nothing in that query names Chatwoot except the door, and a view written this way keeps
working when the helpdesk behind `SupportCase` is a different product. Nothing is mirrored:
every traversal reads Chatwoot at query time, so a conversation resolved in Chatwoot's own UI
is gone from the open cases on the next ask. People keep working in Chatwoot; this realm is
how the rest of the business finds out what they know.

## What's inside

- `apis/` — three operations of Chatwoot's application API, vendored and curated, each with
  what was found by calling it: `status` narrows at the source; `sort_by=created_at_asc` is
  the only stable order to page by; the filter endpoint's `values` is **not** an IN-list.
  Two of them write:
  - `chatwootConversationAssign` puts a conversation in an agent's or a team's queue
    (`assignee_id: 0` unassigns).
  - `chatwootMessageCreate` adds a message. `private` is required, so a reply to the customer is
    never sent by default: `true` makes an internal note, `false` delivers it on the
    conversation's channel, after which it cannot be recalled.

  Each declares `x-embabel-effect`: what it changes, whether it can be undone, and which
  arguments identify a repeat. `chatwootMessageCreate` is `sensitive`, because unless the message is
  private the customer receives it, so an agent asks a person before sending one even when its
  authority lets it act.
- `types/` — `ChatwootDesk` (the door, pinned by status, default `all`),
  `ChatwootConversation` (`parents: [SupportCase]`), `ChatwootMessage`
  (`parents: [SupportMessage]`).
- `producers/` — the desk by status, one account's cases by company domain, and a
  conversation's thread.
- `views/` — `ChatwootOpenCases` (filterable by priority and by account),
  `ChatwootOpenCasesByAccount`, `ChatwootCaseCounts`. All prefixed: view names resolve
  globally across realms.
- `tests/verify.sh` — ground truth from Chatwoot itself, then the traversal by the
  vocabulary's labels, then the views. Exact equality, one command.
- `tests/verify-writes.sh` — each write verb through the appliance, against a scratch contact and
  conversation it deletes afterwards. A seeded conversation is never touched: Chatwoot cannot
  backdate, so a note would move its last activity to now. `verify.sh` runs it with
  `VERIFY_WRITES=1`.
- `stack/` — a disposable Chatwoot in Docker with its first boot automated.
- `seed/load_book.py` — loads the support part of a product-neutral book.

## Working on a conversation you found

`ChatwootConversation` carries methods, written in TypeScript in `src/api/conversation.ts`, so a
conversation found by a query is worked on where it is found:

| Method | Does |
|---|---|
| `assign({agentId?, teamId?})` | puts it in an agent's or a team's queue |
| `unassign()` | takes it out of the queue |
| `addNote(text)` | an internal note only agents see |
| `reply(text)` | a reply delivered to the customer; it cannot be recalled |

Writing for the team and writing to the customer are separate methods, not a flag, so a reply is
never sent by accident. Read with `gateway.cypher.query`, bind a row with `state.set`, then call
the method on `state.get(...)`. To change one: edit `src/api/`, `npm test`, `npm run build`, and
commit `dist/` with it.

## Setup

1. **realm-business-vocabulary installed first.** It declares `SupportCase` and
   `SupportMessage`. A realm cannot yet declare that it needs another.
2. A Chatwoot and a user's access token (Profile settings → Access Token). For a demo,
   `stack/` brings one up and mints the token.
3. `CHATWOOT_API_TOKEN` in the appliance's environment (`secrets.env` beside the compose file
   on the Docker appliance).
4. The server URL in `apis/chatwoot.json` is the one install-specific fact, and it holds two
   things: where Chatwoot is **as the appliance reaches it**, and the **account id**.
5. Install by reference from the appliance's realms mount, then `realm_refresh` after edits.

## The custom attributes this realm reads

Chatwoot is an inbox: a conversation has no subject, no company, and only the time its row was
created. A desk that wants those records them as conversation custom attributes — which is
what Chatwoot provides them for — and this realm reads these:

| Attribute | Becomes | |
|---|---|---|
| `account_key` | `accountKey` | the requester's company domain; the cross-product join key |
| `subject` | `subject` | |
| `kind` | `kind` | bug, feature-request, question, … |
| `opened_on`, `updated_on`, `closed_on` | `openedOn`, `updatedOn`, `closedOn` | the business dates, not the row's |
| `reply_count` | `replyCount` | |
| `case_id` | `caseRef` | the desk's own reference, where it keeps one |

`seed/load_book.py` writes exactly these. A real desk that does not keep them gets those
properties empty, and everything Chatwoot holds natively — status, priority, requester, labels,
the thread — regardless.

## Where this realm falls short of the vocabulary, and why

A producer's `project` can RENAME a source field. It cannot compute one, and a realm's wasm
handlers are granted the graph and SQL, not other APIs, so there is nowhere in a realm to
reshape a record on its way in. Three things the vocabulary specifies are therefore absent
here — absent, not faked:

| The contract asks for | What this realm gives |
|---|---|
| `sourceUrl` | nothing. Build it from `id`: `<chatwoot>/app/accounts/<account>/conversations/<id>` |
| `status`: open, pending, resolved | Chatwoot's own word, which adds `snoozed` (should fold into pending) |
| `SupportMessage.fromCustomer` | `messageType`: 0 customer, 1 agent, 2 Chatwoot's own activity line |

## The account join, and why it cannot be exercised yet

`ChatwootConversation` declares the vocabulary's own edge from the vocabulary's own anchor:

```yaml
- { anchorLabel: CustomerAccount, relationship: HAS_CASE, keyField: accountKey, … }
```

so **any** CRM realm whose accounts carry an `accountKey` reaches this desk's cases, and this
realm has never heard of that CRM. It is declared and it validates. It has not been seen to
work, because no CRM realm can produce an `accountKey` yet: Odoo holds a website URL, turning
`https://www.acmecorp.com` into `acmecorp.com` is a computation, and see the section above.

## Things found the hard way

- An **optional view filter must test a plain variable**, after a `WITH`. Written against the
  node (`$p = '' OR c.priority = $p`), the engine lifts `c.priority = ''` out of the `OR` as a
  predicate on the fetched records, and an empty parameter filters out every row — a view that
  returns nothing, with no warning. `tests/verify.sh` is what caught it.
- A **path parameter needs string mode** (`keyTemplate: "{key}"` with `"{keys}"` in `args`).
  List mode asked Chatwoot for conversation `[182]`.
- The host reads producer YAML **without resolving anchors**, so the two conversation
  producers carry the same `project` written out twice. Keep them identical.
- Chatwoot's **default conversation order moves while you page** (it is by last activity).
  `sort_by=created_at_asc` does not.
