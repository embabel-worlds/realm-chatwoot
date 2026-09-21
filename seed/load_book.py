#!/usr/bin/env python3
"""Load the support part of a neutral book into Chatwoot, through Chatwoot's own REST API.

A BOOK is a directory of product-neutral CSVs (crm/, support/, billing/) joined by
`account_key`, the customer's domain. This loader reads only support/ and knows only
Chatwoot. A case becomes a conversation; its requester becomes a contact.

    CHATWOOT_API_TOKEN=... CHATWOOT_ACCOUNT_ID=1 CHATWOOT_INBOX_ID=1 \\
        ./load_book.py --book ~/dev/sample-business-data/book --yes
    ... ./load_book.py --book ... --remove --yes

It follows the realm spec's rules for seeds: it refuses to run without --yes, a second run
changes nothing, and what it creates is recognizable — every conversation carries the
book's case id as a custom attribute, which is also how a re-run knows it is already there.

Two things about a case do not survive the trip, and the report says so rather than
hiding it. Chatwoot stamps a conversation when it is created, so the book's opened,
updated and closed dates travel as custom attributes instead. And the book knows how many
replies a case had but not what they said, so the count travels and the replies do not:
inventing a thread would be putting words in a customer's mouth.
"""

import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Shown on every conversation in Chatwoot's sidebar. Declared up front because Chatwoot
# stores an undeclared attribute but will not display it, and a date nobody can see is
# not much of a date. Display types are Chatwoot's own: 0 text, 1 number, 5 date.
ATTRIBUTES = [("case_id", "Case id", 0), ("subject", "Subject", 0), ("account_key", "Account", 0), ("kind", "Kind", 0),
              ("opened_on", "Opened on", 5), ("updated_on", "Last updated on", 5),
              ("closed_on", "Closed on", 5), ("reply_count", "Replies", 1),
              ("engineers", "Engineers", 0), ("milestone", "Milestone", 0)]


class Chatwoot:
    """Chatwoot's REST API, PACED.

    Chatwoot rate-limits writes, and this loader makes several calls per case. Without
    pacing a book of any size dies partway through with `429 Retry later` — and it died
    LOUDLY but not safely: the failure came after hundreds of conversations were already
    created, so the run had to be removed before it could be retried, and the remove pass
    hit the same wall. A 2,000-account book never finished loading at all, which meant
    nothing above a couple of hundred cases could be measured.

    So: a minimum gap between calls, and a retry on the statuses that mean "later" rather
    than "no". `Retry-After` is honoured when Chatwoot sends it, because a server that
    says how long to wait knows better than a backoff curve.
    """

    # Statuses that mean the request was fine and the moment was not.
    RETRYABLE = (429, 500, 502, 503, 504)

    def __init__(self, url, account, token, min_interval=None, max_retries=None):
        self.base, self.token = f"{url.rstrip('/')}/api/v1/accounts/{account}", token
        # Tunable because the right pace depends on the deployment, not on this script.
        self.min_interval = float(os.environ.get("CHATWOOT_MIN_INTERVAL", "0.08")
                                  if min_interval is None else min_interval)
        self.max_retries = int(os.environ.get("CHATWOOT_MAX_RETRIES", "8")
                               if max_retries is None else max_retries)
        self._last = 0.0
        self.waited = 0.0  # total seconds spent backing off, so the report can say so

    def _pace(self):
        gap = self.min_interval - (time.monotonic() - self._last)
        if gap > 0:
            time.sleep(gap)

    def call(self, method, path, body=None):
        for attempt in range(self.max_retries + 1):
            self._pace()
            req = urllib.request.Request(self.base + path, method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={"api_access_token": self.token, "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req) as r:
                    text = r.read()
                    return json.loads(text) if text else None
            except urllib.error.HTTPError as e:
                detail = e.read().decode(errors="replace")[:400]
                if e.code not in self.RETRYABLE or attempt == self.max_retries:
                    raise SystemExit(f"Chatwoot refused {method} {path}: {e.code} {detail}")
                # Chatwoot's own number first; otherwise back off, capped so a long
                # book cannot stall for minutes on one bad moment.
                after = e.headers.get("Retry-After") if e.headers else None
                delay = float(after) if after and after.replace(".", "", 1).isdigit() else min(2 ** attempt, 30)
                self.waited += delay
                print(f"chatwoot: {e.code} on {method} {path} — waiting {delay:g}s "
                      f"(attempt {attempt + 1}/{self.max_retries})", file=sys.stderr)
                time.sleep(delay)
            finally:
                self._last = time.monotonic()

    def has_case(self, case_id):
        """Whether a conversation already carries this case id.

        Asked one case at a time, by exact match. Listing every conversation and looking
        through the pages is NOT safe: the list is ordered by last activity, Chatwoot's
        background jobs are still touching conversations after a load, and a conversation
        that moves between pages while they are being read is simply never seen — which
        made a second run create a duplicate.
        """
        hits = self.call("POST", "/conversations/filter", {"payload": [{
            "attribute_key": "case_id", "filter_operator": "equal_to", "values": [case_id],
            "custom_attribute_type": "conversation_attribute"}]})
        return hits["meta"]["all_count"] > 0


def rows(book, name):
    with open(book / name, newline="") as f:
        return list(csv.DictReader(f))


def label_name(label):
    # Chatwoot allows letters, digits, hyphens and underscores in a label. The book's
    # "area:api" style survives as "area-api", which still reads as what it was.
    return label.strip().replace(":", "-")


def load(cw, inbox, book):
    made = {"contacts": 0, "conversations": 0, "labels": 0}
    cases = rows(book, "support/cases.csv")

    declared = {d["attribute_key"] for d in cw.call("GET", "/custom_attribute_definitions?attribute_model=0")}
    for key, name, kind in ATTRIBUTES:
        if key not in declared:
            cw.call("POST", "/custom_attribute_definitions", {"attribute_display_name": name, "attribute_key": key,
                                                              "attribute_display_type": kind, "attribute_model": 0})

    have = {l["title"] for l in cw.call("GET", "/labels")["payload"]}
    wanted = sorted({label_name(l) for c in cases for l in [c["kind"]] + c["labels"].split(",") if l})
    for title in wanted:
        if title not in have:
            cw.call("POST", "/labels", {"title": title, "show_on_sidebar": True})
            made["labels"] += 1

    contacts = {}

    def contact(case):
        email = case["requester_email"]
        if email not in contacts:
            hits = cw.call("GET", "/contacts/search?q=" + urllib.parse.quote(email))["payload"]
            hit = next((h for h in hits if h.get("email") == email), None)
            if not hit:
                hit = cw.call("POST", "/contacts", {
                    "inbox_id": inbox, "name": case["requester_name"], "email": email, "identifier": email,
                    "additional_attributes": {"company_name": case["account_name"]},
                    "custom_attributes": {"account_key": case["account_key"]}})["payload"]["contact"]
                made["contacts"] += 1
            source = next(ci["source_id"] for ci in hit["contact_inboxes"] if ci["inbox"]["id"] == inbox)
            contacts[email] = (hit["id"], source)
        return contacts[email]

    # Oldest first, so conversation numbers rise in the order the cases were opened.
    for c in sorted(cases, key=lambda r: (r["opened_on"], r["source_id"])):
        if cw.has_case(c["source_id"]):
            continue
        cid, source = contact(c)
        text = f"**{c['subject']}**\n\n{c['body']}"
        behalf = c["filed_on_behalf"] == "yes"
        body = {"source_id": source, "inbox_id": inbox, "contact_id": cid, "status": "open",
                "custom_attributes": {k: v for k, v in {
                    # Chatwoot is an inbox and a conversation has no subject of its own; the
                    # realm reads this one, so a case can be listed by what it is about.
                    "case_id": c["source_id"], "subject": c["subject"],
                    "account_key": c["account_key"], "kind": c["kind"],
                    "opened_on": c["opened_on"], "updated_on": c["updated_on"], "closed_on": c["closed_on"],
                    "reply_count": int(c["reply_count"]), "engineers": c["engineers"], "milestone": c["milestone"]}.items() if v != ""}}
        conv = cw.call("POST", "/conversations", body)["id"]
        if not behalf:
            # Posted separately and marked incoming. A message passed along with the new
            # conversation is recorded as the AGENT's, which would show the customer's
            # complaint in the vendor's voice — and leave nobody waiting for a reply.
            cw.call("POST", f"/conversations/{conv}/messages", {"content": text, "message_type": "incoming"})
        else:
            # The vendor's own staff wrote this up after a call. It goes in as a private
            # note from an agent, because the customer never typed it.
            cw.call("POST", f"/conversations/{conv}/messages",
                    {"content": f"Filed on behalf of {c['requester_name']} by {c['filed_by']}.\n\n{text}",
                     "message_type": "outgoing", "private": True})
        if c["priority"] != "none":
            cw.call("POST", f"/conversations/{conv}/toggle_priority", {"priority": c["priority"]})
        cw.call("POST", f"/conversations/{conv}/labels",
                {"labels": [label_name(l) for l in [c["kind"]] + c["labels"].split(",") if l]})
        if c["status"] != "open":
            # Last of all. Chatwoot reopens a conversation whenever the customer writes,
            # so a status set before the opening message does not outlive it.
            cw.call("POST", f"/conversations/{conv}/toggle_status", {"status": c["status"]})
        made["conversations"] += 1
    return made


def remove(cw, book):
    emails = {c["requester_email"] for c in rows(book, "support/cases.csv")}
    gone = 0
    for email in sorted(emails):
        for hit in cw.call("GET", "/contacts/search?q=" + urllib.parse.quote(email))["payload"]:
            if hit.get("email") == email:
                cw.call("DELETE", f"/contacts/{hit['id']}")
                gone += 1
    print(f"chatwoot: removed {gone} contacts, and with them their conversations. "
          f"Labels and attribute definitions are left: they are configuration.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--book", required=True, type=Path)
    ap.add_argument("--url", default=os.environ.get("CHATWOOT_URL", "http://127.0.0.1:3100"))
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--yes", action="store_true", help="confirm that the target is disposable")
    args = ap.parse_args()
    env = {k: os.environ.get(k) or sys.exit(f"{k} is not set") for k in
           ("CHATWOOT_API_TOKEN", "CHATWOOT_ACCOUNT_ID", "CHATWOOT_INBOX_ID")}
    if not args.yes:
        sys.exit(f"This would write into {args.url} — a system you must consider disposable.\nRe-run with --yes to proceed.")
    cw = Chatwoot(args.url, env["CHATWOOT_ACCOUNT_ID"], env["CHATWOOT_API_TOKEN"])
    if args.remove:
        return remove(cw, args.book)
    made = load(cw, int(env["CHATWOOT_INBOX_ID"]), args.book)
    print("chatwoot: created " + ", ".join(f"{n} {what}" for what, n in made.items()) if any(made.values())
          else "chatwoot: everything in the book was already there; nothing changed")
    print("chatwoot: conversation dates are today's; the book's opened, updated and closed dates are custom attributes.\n"
          "chatwoot: each case arrives as its opening message only — the book counts replies but does not hold them.")


if __name__ == "__main__":
    main()
