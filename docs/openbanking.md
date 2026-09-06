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

## Institution discovery (`GET /aspsps`)

`GET /aspsps?country=<ISO2>` returns the supported banks for a country — public
metadata, no personal or consent data. Drives the client's institution picker
(`StartConnectionSheet`) via `BankProvider.list_institutions`. From a live
`country=IT` call (2026-08-27): 338 entries. Fields per entry:

| Field | Coverage (IT) | Notes |
| --- | --- | --- |
| `name` | 338/338 | The provider-scoped identifier — pass straight back as `StartConnectionRequest.institution`. |
| `country` | 338/338 | ISO 3166-1 alpha-2. |
| `logo` | 338/338 | `string(uri)`. URL shape `https://enablebanking.com/brands/{country}/{percent-encoded name}/` (deterministic from `name`+`country`). Serves `image/png` (~5431×1200), `CORS: *`, `cache-control: immutable`. Uploadcare-style transform suffixes work: `.../-/resize/120x/` → `image/webp`. Public branding — not sensitive. Passed through to `InstitutionResponse.logo` and **persisted** on the connection (`connections.institution_logo`) at connect time, so Conti can render it without a second `/aspsps` call; the client resizes it with the `-/resize/` suffix and falls back to a lettermark. A connection authorized before this column existed carries `NULL`; `POST /connections/backfill-logos` fills those in idempotently by matching each connection's stored `name` (case- and whitespace-insensitive) against the provider's institution list for its `country`, falling back to `TRACCIO_DEFAULT_INSTITUTION_COUNTRY` when the connection also predates the `country` column — and writing that resolved country back, which also unblocks in-place re-authorization for those rows. The client calls it once, opportunistically, when it sees a connection with no logo. |
| `bic` | 252/338 | Bank identifier code; absent for some (e.g. PayPal). |
| `psu_types` | 338/338 | e.g. `["personal", "business"]`. |
| `auth_methods` | 338/338 | Authentication approaches offered. |
| `beta` | 338/338 | Implementation-status flag. |
| `maximum_consent_validity` | 338/338 | Seconds; the ceiling for the `valid_until` we request. |
| `required_psu_headers` | 36/338 | The per-ASPSP PSU-header requirement referenced in "Operational constraints" — present only where the bank demands specific headers. |

## Consent flow

How a `Connection` is authorized, as implemented by the Enable Banking adapter
(`providers/enable_banking/`). Three steps across two backend requests:

1. **Start** (`POST /auth`). The adapter sends `aspsp` (`name` + `country`),
   `access` (with a `valid_until` requested at the 180-day maximum), a random
   `state` (anti-CSRF), the `redirect_url`, and `psu_type=personal`. The response
   carries the SCA `url`. The user opens it in the **system browser** (never a
   WebView) and completes the bank's authentication.
2. **Callback.** The bank redirects to `redirect_url` with `code` and the echoed
   `state` in the query (or `error` / `error_description` on failure).
3. **Complete** (`POST /sessions`). The adapter checks the returned `state`
   matches the one it issued (constant-time), then exchanges `code` for a
   session. The response `session_id` is **the credential** for all later data
   calls, and `access.valid_until` becomes `Connection.expires_at`.

The adapter is **stateless**: it generates `state` and returns it as the
`session_reference`; persisting the `state`→pending-`Connection` pairing (so the
callback can be matched to the right connection and user) is the caller's job.
`session_id` is a secret — encrypted at rest (Fernet, ADR 0003), never logged,
never returned by any endpoint. The SCA `url` embeds `state`, so it is not logged
either.

## Account retrieval

Once a `Connection` is active, its accounts are fetched with the stored
`session_id` (the credential) by `POST /connections/{id}/sync`, which drives the
adapter's `list_accounts`. Two provider calls per sync:

1. **`GET /sessions/{session_id}`** returns the `accounts` array — the account
   **UIDs** the session exposes (not full objects).
2. **`GET /accounts/{account_uid}/details`** returns the full `AccountResource`
   for each UID: `identification_hash`, `cash_account_type`, `currency`,
   `product`, and — deliberately unused — the account-holder `name`.

The adapter normalizes each into a provider-agnostic `ProviderAccount`; the
`api/` handler injects `user_id`/`connection_id` and upserts it (idempotent on
`(user_id, identification_hash)`, so a re-sync updates rather than duplicates).

**Normalization duties for this adapter:**

- **Stable identity.** Enable Banking supplies a per-account
  `identification_hash`, documented as stable for matching an account across
  sessions and re-authorizations. It is used directly as the domain
  `Account.identification_hash`; the raw IBAN never leaves the adapter (a purely
  derived, non-reversible identity satisfies both the domain rule — "not the
  bank's account id" — and data-safety).
- **Account kind.** ISO 20022 `cash_account_type` maps to `AccountKind`:
  `CACC`→`current`, `SVGS`→`savings`, `CARD`→`card`, `OTHR`→`wallet` (a
  currency-agnostic wallet such as PayPal, which also reports `currency='XXX'` —
  stored as-is, since the per-transaction currency is authoritative). Any other
  value the bank reports (`CASH`, `LOAN`) is **refused** (`ProviderError`)
  rather than coerced, so an unmodelled account fails loudly instead of
  masquerading as a current account.
- **Display name.** The bank's proprietary `product` name is used as
  `Account.name`. The `AccountResource.name` field is the **account-holder
  name** — personal data — and is never stored or logged (`.claude/rules/data-safety.md`).

## Transaction retrieval

Once accounts are known, each one's transactions are fetched with the stored
`session_id` by the same `POST /connections/{id}/sync`, which drives the adapter's
`fetch_transactions`. The endpoint is
`GET /accounts/{account_uid}/transactions?date_from=…&date_to=…`, paginated: a
response carries a `continuation_key` while more pages remain, passed back on the
next call until it is absent. The provider follows the pages and normalizes each
entry; the `api/` handler upserts each transaction idempotently.

**Account UID resolution.** The transactions endpoint is keyed by Enable
Banking's session-scoped `account_uid`, but the stored domain `Account` carries
only the stable `identification_hash` (the `uid` deliberately does not cross the
adapter boundary). So `fetch_transactions` re-resolves the uid each call: it lists
the session's uids and matches on the `identification_hash` from each account's
details. This is stateless at the cost of a few extra detail calls — acceptable
at the handful-of-accounts scale a personal sync runs at.

**Greedy history window.** The initial sync after a new connection is the only
chance at full history — most banks serve it only for the ~1h following
authorization, then roughly 90 days. So the sync requests a deliberately wide
`date_from` (`TRACCIO_INITIAL_HISTORY_DAYS`, ~2 years by default). Deduplication
makes re-fetching the same window harmless; incremental, budget-aware windowing
lands with the background scheduler.

**Normalization duties for this adapter:**

- **Sign.** Enable Banking sends an unsigned `amount` plus an ISO 20022
  `credit_debit_indicator`: `DBIT` → money left the account (stored **negative**),
  `CRDT` → money arrived (stored **positive**), any other value refused. This is
  the account-holder's perspective, so it is already correct for current, savings,
  and card accounts alike, and no kind is inverted today. Should a specific bank be
  found to report card movements inverted, the per-bank branch is added in the one
  `_normalize_sign(kind, cents)` seam — and recorded below — never scattered across
  call sites (`docs/domain.md`: "a purchase is stored negative, for every account
  type").
- **Amount → integer cents.** The `amount` is a decimal *string* (e.g. `"12.34"`),
  parsed with `Decimal` and scaled ×100 — never through `float` (root `CLAUDE.md`).
  M1 targets two-decimal currencies (EUR, GBP, …); an amount with sub-cent
  precision is **refused** rather than rounded. A zero- or three-decimal currency
  (JPY, BHD) would need its own scale and is a future item.
- **Stable identity.** Prefer the bank's `entry_reference` (`KeyStrategy.ENTRY_REFERENCE`;
  ISO 20022 caps it well under the `stable_key` column). Absent, derive a SHA-256
  over `(account_id, value_date, amount, currency, description)` — a 64-char digest,
  deterministic across syncs but `KeyStrategy.DERIVED_HASH` (lower confidence: two
  identical coffees on the same day collide). The strategy is stored so dedup can
  tell the cases apart.
- **Dates.** `booking_date` → `booked_at` (absent while pending, and no
  fallback exists for it — `None` is the modelled "not yet settled" signal).
  `value_date` → `value_date`, falling back to `transaction_date` when the
  bank sends `value_date` as `null` — found 2026-08-20 debugging PayPal, whose
  entries carry `booking_date`/`value_date` always `null` but
  `transaction_date` always present. ISO dates parse to tz-aware UTC.
- **Description.** The `remittance_information` lines are joined **verbatim** as
  the raw `description` — Enable Banking does not enrich (no clean merchant name).
  A bare string is also tolerated. When a bank sends no remittance text at all
  (PayPal sends an always-empty list), the description falls back to the
  counterparty's name on the side implied by `credit_debit_indicator`: the
  creditor on a debit, the debtor on a credit. A cleaned `display_description`
  is produced separately, later.
- **Status.** `BOOK` → `booked`, `PDNG` → `pending`, `RJCT` → `rejected` (a
  refused/reversed movement, terminal like booked — first seen in the PayPal
  ledger). Any other code (e.g. `INFO`) is still refused, so an unmodelled status
  surfaces on its first real sync rather than masquerading as a booked movement.

**Persistence and dedup.** Each transaction is upserted on the
`(account_id, stable_key)` unique constraint (idempotency enforced at the schema
level, `docs/architecture.md`). A booked row is immutable; a still-pending row is
the same movement transitioning state, so its bank-sourced fields are refreshed on
settlement — but a sync **never** overwrites the user/detection-owned `role` or
`display_description`.

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

The **encryption scheme for tokens/consents stored per `Connection`** is
decided in `docs/decisions/0003-token-encryption-at-rest.md`: Fernet
(`cryptography`), one key held outside the DB in `TRACCIO_ENCRYPTION_KEY`. The
primitive lives in `core/crypto.py`; wiring it into credential storage is part
of the adapter work.

## Redirect URL

**M1 value: `https://localhost:8000/connections/callback`.** After the user
completes SCA the bank returns the browser to this URL with a `code` query
parameter, which the backend exchanges for a session.

Registration constraints observed against Enable Banking production:

- **`https` is mandatory** — an `http://` redirect is rejected at registration
  ("unsupported scheme"). `https` + `localhost` is accepted, which is what makes
  the local-backend flow viable for M1.
- The URL is **editable after registration** via the Control Panel API/CLI, so
  this value is not locked in.

The on-device flow is deferred to **M3**: on a physical iPhone `localhost` does
not reach the Mac backend, so that will use an **Apple Universal Link** (an
`https` URL on a domain we control, e.g. GitHub Pages, hosting the
`apple-app-site-association` file) or a backend-hosted `https` callback. Bank
authorization always runs in the **system browser**, never an in-app WebView:
bank SCA apps often fail to open from a WebView (`client/CLAUDE.md`).

## Operational constraints

These are hard constraints on product design, not tuning parameters.

- **Consent lifetime.** For most banks the maximum session lifetime is
  **180 days**, after which the user must re-authorize
  (`docs/domain.md`, `Connection.expires_at`). Expiry is a first-class product
  concern: an expired connection silently stops producing data. **Backend
  shipped 2026-08-21** (ADR 0006): `domain/consent.py::consent_state`
  re-reads a stored `active` status against `expires_at` and the clock, never
  storing an expiry flag; `GET /connections` exposes `consent_state` +
  `days_until_expiry`, `POST /connections/{id}/sync` refuses (`409
  consent_expired`) before calling the provider on a lapsed consent, and
  `POST /connections/{id}/reauthorize` re-arms the *same* connection row for
  a fresh SCA round rather than creating a new one. **Surfacing the warning in
  the client UI remains M3 client catch-up.**
- **Background fetch budget.** Many banks allow only **~4 background fetches
  per day per consent**; exceeding it gets the consent throttled
  (`docs/domain.md`, Sync). Blocked on the M3 background scheduler — there is
  no background sync yet (every sync is a manual `POST`), so there is nothing
  to budget.
- **PSU-present headers.** User-present requests (the user is actively
  waiting) carry PSU headers signalling this and are not subject to the
  background budget. Confirmed against the Enable Banking reference
  (2026-08-21): the header set is `Psu-Ip-Address`, `Psu-User-Agent`,
  `Psu-Referer`, `Psu-Accept`, `Psu-Accept-Charset`, `Psu-Accept-Encoding`,
  `Psu-Accept-language`, `Psu-Geo-Location` — **all-or-nothing** per request
  (providing some but not the bank's `required_psu_headers` set returns
  `PSU_HEADER_NOT_PROVIDED`), and which ones a given bank actually requires
  comes from `required_psu_headers` on its ASPSP details, not a fixed list.
  **Not yet implemented**: `providers/base.py::SyncContext(psu_present=...)`
  is threaded through `EnableBankingProvider.list_accounts`/
  `fetch_transactions` but both discard it (`del context`) — no header is
  actually sent. Doing this properly needs a design decision this backend
  doesn't have yet (where a PSU IP/user-agent enters a headless HTTP API), so
  it stays open as its own backlog item rather than folded into the
  consent-lifecycle slice above.
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
| Revolut | No — only `current` accounts, one per currency (EUR/CHF/TRY); no `CARD`/`SVGS` | Good — `remittance_information` populated on every entry (merchant/counterparty text), no enrichment | `entry_reference` on 100% of entries → `KeyStrategy.ENTRY_REFERENCE` always, hash fallback never used. `product` absent → `Account.name` is `null`. Sign: `DBIT`→negative confirmed, no card inversion. A `pending` entry still carried a `booking_date` (so `booked_at` set while pending); `value_date` absent only on that pending row. First real sync 2026-08-20: 3 accounts, 374 transactions; re-sync added 0 duplicates. The API institution string is `Revolut`. |
| Isybank | No — one `current` EUR account; no `CARD`/`SVGS` | Good — `remittance_information` populated on every entry, no enrichment | `entry_reference` on 100% of entries → `KeyStrategy.ENTRY_REFERENCE` always. `product` absent → `Account.name` is `null` (same as Revolut). Every entry had both `booked_at` and `value_date`; no pending in the synced window. First real sync 2026-08-20: 1 account, 14 transactions; re-sync added 0 duplicates. API institution string: `Isybank`. |
| PayPal | N/A — single `wallet` account | Poor as shipped — `booking_date`/`value_date` are always `null` (not absent) and `remittance_information` is always an always-empty list; `merchant_category_code` is also always `null`, contrary to what was originally recorded here. `transaction_date` is the only date PayPal ever sends, and `creditor`/`debtor.name` are the only description source, covering 140/141 entries (found and fixed 2026-08-27, see `docs/decisions/0019-...`; a field census of the raw payload is `scripts/eb_field_census.py`) | Exposes one `cash_account_type='OTHR'`, `currency='XXX'` (ISO 4217 "no currency") account → `AccountKind.WALLET` (modelled 2026-08-20); the account-level `XXX` is stored as-is and the per-transaction currency (all `EUR` in the synced window) is authoritative. `product` **present** → `Account.name` is set (unlike Revolut/Isybank). `entry_reference` on 100% of entries → `KeyStrategy.ENTRY_REFERENCE` always. Surfaced a second modelling gap: 1 entry with status `RJCT` (rejected/reversed) → now `TransactionStatus.REJECTED` (terminal like booked, zero effective spending at M2). Indicators `DBIT`/`CRDT` only, amounts all two-decimal. First real sync 2026-08-20: 1 account, 141 transactions (140 booked, 1 rejected); re-sync added 0 duplicates. API institution string: `PayPal`. |

Coverage note (from ADR `0001`): card-account access was extended in March
2026 to BPER, Postepay, Fineco, Banco BPM/Bibanca, and Nexi including YAP.
Confirm coverage for the specific accounts to be linked before relying on it.
