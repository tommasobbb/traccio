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

| Layer        | Contains                                   | May import        |
| ------------ | ------------------------------------------- | ----------------- |
| `domain/`    | Entities, value objects, derivation rules  | nothing           |
| `services/`  | Sync, matching, detection, categorization  | `domain`          |
| `providers/` | Bank adapters                              | `domain`          |
| `db/`        | Persistence, repositories                  | `domain`          |
| `api/`       | HTTP routing, request/response schemas     | all of the above  |
| `core/`      | Config, logging, crypto, auth              | nothing           |

`domain/` importing SQLAlchemy or FastAPI is a bug. It must stay testable
with no database and no network.

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

**Every query is scoped by `user_id`.** No exceptions, including admin and
debug paths.

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

## Client

The Swift client is thin on logic and thick on presentation.

`TraccioCore` (SwiftPM package) holds models, the API client, and formatting.
It builds and tests from the command line with no Xcode, which is what makes
it verifiable by an agent. The app target holds views, navigation and
platform wiring only.

Models are generated from `docs/api/openapi.json` (`make openapi`), so a
backend field rename becomes a compile error rather than a runtime surprise.

**Local storage is a read cache, not a source of truth.** The client
persists what it fetched so the app opens instantly and reads offline. It
never computes derived values and never resolves conflicts: on refresh, the
server response replaces the cache. User actions are sent to the server and
the result is what gets stored.

Actions taken offline are refused rather than queued, for now. A write queue
is the planned escape hatch if this proves annoying in practice (see
`tasks/backlog.md`, M3) — it layers on top of the read cache without
changing it.

## Security

Bank tokens are encrypted at rest with a key held outside the database.
They are never logged, never returned by any endpoint, and never leave the
backend — the client has no notion that tokens exist.

Authorization redirects use the system browser. Never an in-app WebView:
bank SCA apps often fail to open from one (see `openbanking.md`).

See `.claude/rules/data-safety.md` for what must never reach logs.

## Deliberately absent

- No message queue, no Celery, no Redis. Sync runs in a background task;
  when that stops being enough, revisit — not before.
- No caching layer. Postgres is the cache.
- No microservices.
- No GraphQL.
- No payment initiation, ever. Read-only by design.