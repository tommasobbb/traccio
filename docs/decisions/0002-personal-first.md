# 0002 — Ship as a personal tool first, decide about a business later

Status: accepted
Date: 2026-08-01

## Context

The original intent was a public product with paying users. Investigating
the actual requirements changed the sequencing, not the ambition.

Three constraints apply the moment the app reads other people's bank
accounts:

1. **App Store guideline 5.1.1(ix)**: apps in highly-regulated fields
   (banking and financial services) or handling sensitive user information
   must be submitted by a legal entity, not an individual developer. Apple
   enforces this; rejections are documented. A D-U-N-S number requires a
   recognized legal entity — trade names and DBAs are not accepted — so in
   Italy this realistically means an SRL, not a ditta individuale.
2. **Aggregators do not contract with individuals**: a signed contract, KYB
   and a monthly minimum, payable before the first user exists.
3. **GDPR**: Traccio becomes data controller for third parties' financial
   data — DPA, records of processing, 72-hour breach notification, likely a
   DPIA.

Fixed costs before any revenue land somewhere around €4.000–9.000/year.
Against an already crowded Italian market (Spendee, BudgetBakers Wallet,
Revolut, Money Lover all offer open banking sync), reaching break-even
requires roughly 400–600 paying subscribers.

Meanwhile, the single question that determines whether the product is worth
anything — *is the bank data good enough for these features?* — can be
answered for free in a few weeks via Enable Banking restricted production.

## Decision

Build the complete product, all features included, for one user, on real
data, at zero cost. Reassess at M4 after at least three months of real daily
use.

No irreversible spending — legal entity, aggregator contract, App Store —
before that review. Paid Apple Developer membership as an *individual*
(~€99/yr) is the only expense, and it buys distribution rights we do not
need: it removes the 7-day certificate expiry and allows installing on up to
100 devices. That is enough for personal and family use without any of the
above.

**The default outcome of M4 is "keep it personal." That is a success.**

## Consequences

- Multi-tenancy is designed in from day one but exercised by one user. Cheap
  now, avoids a rewrite if M4 goes the other way.
- Token encryption at rest is built from the start, because migrating
  sensitive data in production later is the worst possible time.
- Feature priority follows what is *differentiating and data-independent*
  (transfers, events, advances, reimbursements) over what is *commodity and
  data-dependent* (categorization).
- If M4 says go public, the fourth-party model under an aggregator's licence
  is the intended path, not obtaining our own AISP authorization.

## What would change this decision

- The data turns out to be unusable for the core features → stop, or scope
  down to manual entry.
- Real demand appears (waitlist, people asking) before M4 → the review can
  happen earlier, but the same three constraints still apply and still cost
  the same.