# Open Banking — Enable Banking

Operational reference for Traccio's bank connectivity. Read this before
touching anything under `backend/src/traccio/providers/` (root `CLAUDE.md`).
It is not a tutorial: it records the onboarding procedure and the constraints
that shape the adapter design.

The provider choice and its rationale live in
`docs/decisions/0001-scelta-aggregatore.md`. Domain concepts referenced here
(`Connection`, consent expiry, sync modes) are defined in `docs/domain.md`.

## Provider and mode

**Enable Banking**, used first in **restricted production**: own accounts
only, no contract, no KYB, no cost. The account holder links their own bank
accounts and data retrieval stays limited to those whitelisted accounts. This
is the M1 mode; going to unrestricted production is an M4 decision (requires a
signed contract, KYB, and therefore a legal entity — see ADR `0002`).

**No enrichment.** Enable Banking is a pass-through: it does not categorize or
clean merchant data. Categorization is entirely Traccio's to build (see the
roadmap: rules-based first, ML deferred). Do not expect a clean merchant name
or a category on any transaction.

## Onboarding (restricted production)

These steps are done **once, by hand, in the Enable Banking Control Panel**.
They produce the application ID and the private key the backend adapter needs.

1. **Create the account.** Go to <https://enablebanking.com/sign-in/> and enter
   your email. The account is created on first sign-in via a magic link; there
   is no password.
2. **(Recommended) Sandbox application first.** In the Control Panel under
   *API applications*, add a new application choosing the **Sandbox**
   environment. Provide an application name (shown to you during the bank
   authorization) and one or more whitelisted **redirect URLs**. On submit the
   browser generates and downloads a **private RSA key** named
   `<application-id>.pem`. Sandbox lets you exercise the flow against test
   banks before touching real accounts.
3. **Create the restricted-production application.** Add another application,
   this time choosing **Production**. It starts in status **Inactive**. This
   also downloads its own `<application-id>.pem`.
4. **Activate by linking accounts.** Use the **"Activate by linking accounts"**
   button and complete the bank's authorization (SCA) flow for your own
   accounts. After you confirm, the application becomes **active in restricted
   mode**; data retrieval is limited to the accounts you linked.
5. **Authenticate from the backend.** Every API request is authorized with a
   **JWT signed RS256** using the `.pem`:
   - header: `kid` = application ID
   - claims: `iss=enablebanking.com`, `aud=api.enablebanking.com`, `iat`
     (now), `exp` (now + 3600s)
   - sent as `Authorization: Bearer <jwt>`

   The JWT is short-lived and minted per request/session by the adapter; it is
   not a stored credential. The **private key is** the credential.

References: Enable Banking docs — `quick-start`, `api/control-panel`,
`tpp/getting-started` under <https://enablebanking.com/docs>.

## Credential handling

The `<application-id>.pem` private key is a secret and is treated like one
(see `.claude/rules/data-safety.md`):

- **Never committed.** The key file is gitignored; it never lands in the repo,
  a fixture, a test snapshot, or the OpenAPI schema.
- **Outside the database.** Its filesystem path comes from configuration
  (`core/config.py`, `TRACCIO_` prefix, documented in `backend/.env.example`),
  not from a table. This matches how `Connection` credentials/tokens are
  handled: encrypted at rest, key held outside the DB (`docs/domain.md`).
- **Never logged.** Not the key, not the minted JWT, not any provider response
  body. If a connection must be identified in a log, log its `connection_id`.

The **encryption scheme for tokens/consents stored per `Connection`** is a
separate, still-open M1 decision ("Token encryption at rest — decide the
scheme before storing anything" in `tasks/backlog.md`). This document only
records the constraint; it does not fix the scheme.

## Redirect URL — open design question

The redirect URL is whitelisted when the application is created and is where
the bank returns the user after authorization. For a native client plus a
local backend the flow is not obvious (custom URL scheme handed back to the
app vs. a backend-hosted callback). **This is deliberately left open here** and
must be decided together with the adapter's authorization flow — do not invent
a provider integration path in this document (root `CLAUDE.md`). Bank
authorization must run in the **system browser**, never an in-app WebView:
bank SCA apps often fail to open from a WebView (`client/CLAUDE.md`).

## Operational constraints

These are hard constraints on product design, not tuning parameters.

- **Consent lifetime.** For most banks the maximum session lifetime is
  **180 days**, after which the user must re-authorize from scratch
  (`docs/domain.md`, `Connection.expires_at`). Expiry is a first-class product
  concern: the client warns before it happens, because an expired connection
  silently stops producing data.
- **Background fetch budget.** Many banks allow only **~4 background fetches
  per day per consent**; exceeding it gets the consent throttled
  (`docs/domain.md`, Sync). The background scheduler tracks consumption per
  connection and refuses rather than overruns.
- **PSU-present headers.** User-present requests (the user is actively
  waiting) carry the PSU headers signalling this and are not subject to the
  background budget. The adapter sets these headers based on the sync mode.
- **Environment ladder.** Sandbox (test banks) → restricted production (own
  linked accounts, free) → unrestricted production (manual review, contract,
  KYB — M4 only).

## Per-bank findings

Filled in during M1 as real data arrives — one row per bank, recording what
the API actually returns. Record findings **as they are discovered**
(`tasks/ROADMAP.md` M1); `tasks/backlog.md` keeps this item open on purpose.
For each adapter also document, per `docs/architecture.md`, its sign
convention per account kind (card accounts invert — a purchase is stored
negative), its stable transaction identity (`entry_reference`, else a derived
hash), and its date semantics (`booked_at` vs `value_date`).

Use synthetic/masked values only — never paste a real bank response, even
redacted (`.claude/rules/data-safety.md`).

| Bank | Card accounts exposed | Description readability | Notable fields / quirks |
| ---- | --------------------- | ----------------------- | ----------------------- |
| _tbd_ | _tbd_ | _tbd_ | _tbd_ |

Coverage note (from ADR `0001`): card-account access was extended in March
2026 to BPER, Postepay, Fineco, Banco BPM/Bibanca, and Nexi including YAP.
Confirm coverage for the specific accounts to be linked before relying on it.
