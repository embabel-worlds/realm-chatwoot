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

- `apis/` — five operations of Chatwoot's application API, vendored and curated, each with
  what was found by calling it or reading its source: the filter endpoint takes a status and a
  window on a date attribute, and its `values` is **not** an IN-list; `q` searches message text and then ignores `status`; a thread asked for
  without `after`/`before` is only its latest 20 messages. Two of them write:
  - `chatwootConversationAssign` puts a conversation in an agent's or a team's queue
    (`assignee_id: 0` unassigns).
  - `chatwootMessageCreate` adds a message. `private` is required, so a reply to the customer is
    never sent by default: `true` makes an internal note, `false` delivers it on the
    conversation's channel, after which it cannot be recalled.

  Each declares `x-embabel-effect`: what it changes, whether it can be undone, and which
  arguments identify a repeat. `chatwootMessageCreate` is `sensitive`, because unless the message is
  private the customer receives it, so an agent asks a person before sending one even when its
  authority lets it act.
- `types/` — three doors onto a case, `ChatwootDesk` (pinned by status, default `all`),
  `ChatwootCompanyCases` (one company, by domain) and `ChatwootTextSearch` (the cases whose
  threads contain some words); `ChatwootConversation` (`parents: [SupportCase]`) and
  `ChatwootMessage` (`parents: [SupportMessage]`).
- `producers/` — the desk by status, one company's cases by domain, the cases Chatwoot's search
  finds for some text, and a conversation's thread.
- `views/` — `ChatwootOpenCases` (filterable by priority), `ChatwootCasesForCompany`,
  `ChatwootCasesMentioning`, `ChatwootOpenCasesByAccount`, `ChatwootCaseCounts`,
  `ChatwootCompanies`. All prefixed: view names resolve globally across realms.
- `tests/verify.sh` — ground truth from Chatwoot itself, then the traversal by the
  vocabulary's labels, then the views, then what they COST: one company without the desk door,
  a thread read whole, words found by Chatwoot's search. Exact equality, one command.
- `tests/verify-writes.sh` — each write verb through the appliance, against a scratch contact and
  conversation it deletes afterwards. A seeded conversation is never touched: Chatwoot cannot
  backdate, so a note would move its last activity to now. `verify.sh` runs it with
  `VERIFY_WRITES=1`.
- `stack/` — a disposable Chatwoot in Docker with its first boot automated.
- `seed/load_book.py` — loads the support part of a product-neutral book.

## What a question costs

Chatwoot lists conversations 25 to a page and throttles each client IP (Rack::Attack, 3,000
requests a minute unless the server says otherwise), so the door a question goes through is most
of what it costs:

| Question | Door | Calls |
|---|---|---|
| everything open, counts by status, busiest companies | `ChatwootDesk` | one per 25 cases in that status (a count alone: one) |
| cases opened, updated or closed after or before a day — `WHERE c.openedOn > '2026-09-01'` | `ChatwootDesk`, the window sent to Chatwoot | one per 25 cases in the window, a count too |
| one company's cases — `WHERE c.accountKey = 'acme.com'` | `ChatwootCompanyCases`, taken by the engine itself | one per 25 of that company's cases (a count alone: one) |
| which cases say some words | `ChatwootTextSearch` | one per 25 cases found, then one thread read per case found |
| a case's thread | `HAS_MESSAGE` | one per case, cached until something is said in it |

A query that pins a case's `accountKey` — inline, by `WHERE`, or with an `IN` list — goes through
the company door without naming it, because the join declares `materializedKeyField: accountKey`.
On the company door a status of `open` or `resolved` and a priority are sent to Chatwoot too;
`pending` is not, because the graph's pending includes Chatwoot's snoozed. On the desk door a
bare business day under `>`, `>=`, `<` or `<=` (`c.openedOn >= '2026-09-01'`, also `updatedOn` and
`closedOn`) is sent, so a dated question reads only its window, and so are a status of `open` or
`resolved` and a priority on the case.
Anything else a case carries (requester, kind, the row clocks) is applied in the graph after the
door it went through, so a question about one company should say the company.

What is NOT pushed, and why:

- **A business-day bound with a time of day** (`c.openedOn >= '2026-09-01T12:00:00Z'`). Chatwoot
  compares by the day, strictly; a bare day under `>=` or `<=` is sent moved by a day
  (`granularity: day`), but part of a day cannot be said, so it stays in the graph.
- **`createdAt` and `lastActivityAt`.** Chatwoot filters them by the day and the graph holds epoch
  seconds, so no bound in the graph's terms names the day Chatwoot compares. Use the business days.

- **`WHERE c.status = 'pending'`** reads the desk at `all` and filters: the graph's pending folds in
  Chatwoot's snoozed, which one Chatwoot status cannot say. `open` and `resolved` are sent.
- **Words in a thread through `(c)-[:HAS_MESSAGE]->(m) WHERE m.body CONTAINS …`**: a filter on
  the message cannot narrow which conversations are read, so that shape reads one thread per case.
  Start from `ChatwootTextSearch` (or the `ChatwootCasesMentioning` view) and only the threads
  Chatwoot found are read.
- **The requester's email or company name**: Chatwoot's conversation filter cannot test the
  contact. `accountKey` is the company key.

Chatwoot's `/search/messages` is not used for text: it looks back three months only, and with
full-text search switched on it matches whole words, so it would find fewer cases than contain the
words. The list endpoint's `q` matches text anywhere in a customer or agent message, all of history.

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
   `SupportMessage`. The realm `requires` it, so installing this realm brings it in.
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

`seed/load_book.py` writes exactly these, and DEFINES them (Settings → Custom Attributes). The
definition matters for `account_key`: Chatwoot's filter silently drops a clause on an attribute
the desk has not defined and answers with every conversation. On such a desk a query that pins
`c.accountKey` is still right (the graph keeps only that company's cases) and merely slow, but
`(a:CustomerAccount)-[:HAS_CASE]->(c)` asked per account links every case to the account: define
the attribute. A real desk that does not keep the attributes gets those properties empty,
and everything Chatwoot holds natively — status, priority, requester, labels, the thread —
regardless.

## Where Chatwoot's shape differs from the vocabulary

A producer's `project` renames a source field and its `compute:` derives one, so the gaps
between Chatwoot and the vocabulary's contract are closed here, once, rather than by every
reader:

| The contract asks for | How this realm gives it |
|---|---|
| `sourceUrl` | built from `id`: `<chatwoot>/app/accounts/<account>/conversations/<id>` (the demo stack's host, as realm-odoo's links are) |
| `status`: open, pending, resolved | Chatwoot's word, with `snoozed` folded into `pending`. The desk door still takes Chatwoot's own words |
| `SupportMessage.fromCustomer` | `messageType = 0`; `messageType` stays beside it (1 agent, 2 Chatwoot's own activity line) |
| `SupportMessage.sentOn` | the day of `sentAt` |
| `tags` | Chatwoot's `labels`, under the vocabulary's name |

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
  `sort_by=created_at_asc` does not, but only the list takes it, and the list takes no date. The
  desk door reads the filter, which is always in last-activity order: a case touched during the few
  seconds of a walk can be missed, and the door's note says so. The text door still reads the list
  in creation order.
- A **thread asked for with no arguments is its latest 20 messages**, silently. The realm asks
  for `after=0&before=2147483648`, the whole thread oldest first up to 1,000.
- A **thread is cached for a day, keyed on the conversation AND its last activity.** Chatwoot moves
  `last_activity_at` on every message it records, so a thread with something new in it is a new
  key and is read again; one that has not moved — every resolved case — is read once.
- With **`q`, Chatwoot ignores `status`** and its `all_count` is not the total; the text door sends
  no status and pages until a short page.
