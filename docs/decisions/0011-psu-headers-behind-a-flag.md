# 0011 — PSU-present headers: built, tested, deliberately not turned on

Status: accepted
Date: 2026-08-24

## Context

`SyncContext(psu_present=...)` has been threaded through
`EnableBankingProvider.list_accounts`/`fetch_transactions` since the M1
adapter shipped (2026-08-20), but both methods discarded it (`del context`)
— no PSU-present header was ever actually sent. This was filed as an open
backlog item and was one of the three things the background sync scheduler
(ADR 0010) was the gate for.

`docs/openbanking.md`, confirmed against the Enable Banking reference: the
full header set is `Psu-Ip-Address`, `Psu-User-Agent`, `Psu-Referer`,
`Psu-Accept`, `Psu-Accept-Charset`, `Psu-Accept-Encoding`,
`Psu-Accept-language`, `Psu-Geo-Location`. Sending it is **all-or-nothing per
request**: providing a subset that doesn't match a given bank's own
`required_psu_headers` (an ASPSP-level field this codebase never fetches)
returns `PSU_HEADER_NOT_PROVIDED` — an explicit failure, on a real request,
against a real consent.

Three of the eight headers have no honest value available today:
`Psu-Ip-Address` and `Psu-Geo-Location` need a real device, and the client
only reaches this backend from `localhost` (`tasks/backlog.md`'s "cannot
reach the backend from a real device" item — unresolved); `Psu-Referer`
names a browser referring page, which has no real equivalent for a
server-to-server API call triggered by a tap in a native app.

## Decision

**Build the plumbing completely, test it thoroughly, and never turn it on
automatically.**

1. `EnableBankingClient`'s three data-retrieval methods (`get_session`,
   `get_account_details`, `get_account_transactions`) accept an optional
   `extra_headers` mapping, merged alongside the bearer JWT.
2. `EnableBankingProvider` takes a new `send_psu_headers: bool` constructor
   parameter (default `False`). Only when **both** `send_psu_headers` and
   the call's `SyncContext.psu_present` are true does it build and attach a
   header set; otherwise behavior is byte-for-byte what it was before this
   parameter existed.
3. The header set actually sent, even when both gates are on, is
   **deliberately partial**: `Psu-User-Agent`, `Psu-Accept`,
   `Psu-Accept-Charset`, `Psu-Accept-Encoding`, `Psu-Accept-language` — five
   of the eight. `Psu-Ip-Address`, `Psu-Geo-Location`, and `Psu-Referer` are
   never sent, at any setting, because fabricating a value for any of them
   would be worse than omitting it. This means turning the flag on does
   **not** make PSU headers "work" for a bank whose `required_psu_headers`
   needs one of the three missing ones — it would still get
   `PSU_HEADER_NOT_PROVIDED`. The flag exists so the honest 80% of the
   plumbing is written, reviewed, and tested now, rather than blocking on
   the two harder open questions below.
4. `Settings.send_psu_headers` (`TRACCIO_SEND_PSU_HEADERS`) defaults to
   `false`. `api/deps.py::build_bank_provider` is the only place that reads
   it and passes it into the provider's constructor.

A version of this that instead fabricated placeholder values for
`Psu-Ip-Address`/`Psu-Geo-Location` (e.g. a static IP) was considered and
rejected: a bank has no way to tell a fabricated PSU IP from a real one, so
this would silently misrepresent who is actually present — worse than the
bank simply refusing the request with a clear error.

## Consequences

- Zero behavior change today and until someone flips
  `TRACCIO_SEND_PSU_HEADERS` to `true` — every existing test and the real
  Enable Banking connections in `dev.db` are unaffected.
- Turning it on is still not "done": it unblocks banks whose
  `required_psu_headers` happens to be a subset of the five sent here, and
  still fails `PSU_HEADER_NOT_PROVIDED` for any bank requiring IP or geo. No
  live verification against a real bank has been run — deliberately, to
  avoid risking a real consent on an incomplete implementation.

## Revisit when

- The client reaches the backend from a real device (`tasks/backlog.md`),
  giving a real PSU IP to send — the honest fix for `Psu-Ip-Address`.
- Enable Banking's ASPSP details (`required_psu_headers`) are fetched and
  stored per connection, so the provider can decide per-bank whether the
  five-header set is sufficient or the sync should skip sending any (today's
  behavior) rather than guess.
