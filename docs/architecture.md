# Architecture

How the pieces fit and which rules must not be broken. For *what* the
concepts mean, read `domain.md` first.

## Shape

SwiftUI app (iOS + macOS)
│ HTTPS / JSON, schema generated from OpenAPI
▼
FastAPI backend ──────► Enable Banking ──────► banks
│
▼
PostgreSQL

The backend owns every decision. The client renders and captures intent.
This is deliberate: business rules that live in two places drift, and a
wrong number in a finance app destroys trust faster than a missing feature.

## Backend layers

Dependencies point inward. A layer may import from layers below it, never
above.

| Layer        | Contains                                   | May import                          |
| ------------ | ------------------------------------------- | ------------------------------------ |
| `domain/`    | Entities, value objects, derivation rules  | nothing                             |
| `services/`  | Sync, matching, detection, categorization  | `domain`, `db`, `providers`, `core` |
| `providers/` | Bank adapters                              | `domain`                            |
| `db/`        | Persistence, repositories                  | `domain`, `core`                    |
| `api/`       | HTTP routing, request/response schemas     | all of the above                    |
| `core/`      | Config, logging, crypto, auth              | nothing                             |

`domain/` importing SQLAlchemy or FastAPI is a bug. It must stay testable
with no database and no network.

Most of `services/` is still pure — `advances.py`, `categorization.py`, and
`transfers.py` import only `domain`, same as the table used to require of the
whole layer. `services/sync.py` is the exception: sync is inherently I/O
orchestration (decrypt a stored credential, call the bank adapter, write
rows), and both an HTTP-triggered sync and the background scheduler run the
exact same path — see ADR 0010 for why the column was widened rather than
duplicating that orchestration once inside `api/` and once in a scheduler
module. What still holds without exception: `db/`, `providers/`, and `core/`
never import `services/`, and `services/` never imports `api/` — HTTP
concerns (status codes, request/response schemas) stay in the router.

`db/session.py`, `db/seed_dev.py`, and `db/seed_demo.py` are the places `db/`
imports `core` (`core.config.get_settings()`, for the database URL and the dev
seed's user id) — the same single-source-of-truth reason Alembic's own
`env.py` reads the DSN from `get_settings()` rather than a second hardcoded
value. Every other module under `db/` (`models`, `mappers`, `repositories/`)
imports only `domain`, unchanged.

## Invariants

These are the rules that make the numbers correct. Breaking one produces
output that looks plausible and is wrong.

**`effective_amount` is derived in exactly one place** — a pure function in
`domain/`. Not in a SQL view, not in a service, never in Swift. Every
dashboard number flows from it. If a client ever computes spending from
`amount`, advances and transfers silently reappear as spending.

**`amount` and `effective_amount` are never mixed.** Balance reconciliation
uses `amount`. Everything user-facing uses `effective_amount`.

**Detection never mutates.** Transfer detection, reimbursement matching and
categorization all write *suggestions*. Only an explicit user action changes
a role, links a reimbursement, or sets `confirmed_category_id`.

**Sync is idempotent.** Running it twice changes nothing. Enforced by a
unique constraint on (account, stable key), not by application logic alone.

**Every query over user data is scoped by `user_id`.** No exceptions,
including admin and debug paths. The only unscoped table is `fx_rates`
(ADR 0021) — cached ECB reference rates are public and identical for every
user, the same category as the seeded `Category` templates.

## Provider adapters

`providers/` is an anti-corruption layer. Provider-shaped data stops there;
everything above it sees only domain objects.

Each adapter implements the same interface: start authorization, complete
authorization, list accounts, fetch transactions. Each adapter is
responsible for normalizing:
- sign convention per account kind (see `domain.md` — card accounts invert)
- stable transaction identity (`entry_reference`, else derived hash)
- date semantics (`booked_at` vs `value_date`)

Each adapter documents its own quirks in `docs/openbanking.md`. Nothing
above `providers/` may branch on which provider or which bank produced a
record. If a service needs to know, the adapter failed to normalize.

Enable Banking is the only adapter today. The interface exists so a second
one does not require touching services.

## Sync

Two entry points, one path:

- **User-present**: triggered by the app, carries PSU headers, no rate
  budget concerns.
- **Background**: scheduled, must respect the per-bank daily fetch budget.
  The budget is a hard constraint (see `domain.md`), so the scheduler tracks
  consumption per connection and refuses rather than overruns.

Pipeline: fetch → normalize (adapter) → deduplicate → persist → run
detection → record `Sync` outcome. Detection failures do not fail the sync;
transactions land, suggestions can be retried.

The initial sync after a new connection is a separate, greedy path: it must
pull maximum history inside the short post-authorization window. There is no
second attempt.

Sync only ever iterates the provider's own account list, and `upsert_account`
matches on `(user_id, identification_hash)` — `null` for a manual account
(ADR 0020), and `NULL != NULL`. So a **manual account** and its hand-entered
transactions are structurally invisible to sync: it cannot adopt, overwrite,
or prune them.

## Client

The Swift client is thin on logic and thick on presentation.

`TraccioCore` (SwiftPM package) holds models, the API client, and formatting.
It builds and tests from the command line with no Xcode, which is what makes
it verifiable by an agent. The app target holds views, navigation and
platform wiring only.

Models are hand-written against `docs/api/openapi.json` (`make openapi`), one
per response shape, each with a decoding test covering the negative cases
(unknown enum value, malformed timestamp) — a backend field rename fails a
test rather than surfacing as a runtime surprise. A real generator
(`swift-openapi-generator` or similar) is a top-level dependency and a
build-plugin step, deliberately not added while there are few enough models
per slice to hand-maintain (`engineering.md`).

**No local read cache.** Every screen fetches fresh from the backend; there
is no offline persistence of financial data to resolve or go stale. The only
local state is the server URL and API token (Keychain) and a biometric-lock
preference (a plain, non-financial `Bool` in `UserDefaults`). Actions taken
offline are refused, not queued — see `engineering.md` for the reasoning and
`tasks/backlog.md` for the open question of whether an offline write queue
is ever worth adding.

## Security

Bank tokens are encrypted at rest with a key held outside the database.
They are never logged, never returned by any endpoint, and never leave the
backend — the client has no notion that *bank* tokens exist. The client does
hold its own, unrelated API token gating access to the backend itself (ADR
0014) — a shared secret, not a bank credential, stored client-side in the
Keychain.

Authorization redirects use the system browser. Never an in-app WebView:
bank SCA apps often fail to open from one (see `openbanking.md`).

See `engineering.md`'s "Data safety" section for what must never reach logs.

## Deliberately absent

- No message queue, no Celery, no Redis. Sync runs in a background task;
  when that stops being enough, revisit — not before.
- No caching layer. Postgres is the cache.
- No microservices.
- No GraphQL.
- No payment initiation, ever. Read-only by design.
- No FX conversion by default. One **opt-in** external rate source
  (frankfurter.dev, ECB rates, `TRACCIO_FX_ENABLED`, ADR 0021) feeds only the
  dashboard's additive `converted` total; the per-currency breakdown is
  unchanged and every other total stays single-currency. Cached rows in
  `fx_rates` — the one table not scoped by `user_id` (public reference data).