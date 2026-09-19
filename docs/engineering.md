# Engineering conventions

How the code in this repo is actually written — the craft level below the
architecture. Read `architecture.md` first for the shape of the system and
the layer rules, and `domain.md` for what the concepts mean; this document
is the "how we write it" layer underneath both, for the backend (Python) and
the client (Swift). `CONTRIBUTING.md` has the commands and the walkthroughs
for adding something new; this document has the reasoning behind the rules
those walkthroughs assume.

The guiding tension throughout is **dependency-light and hand-crafted**. This
is a small, single-user app, not a platform: good engineering here means the
code is easy to change and easy to delete, not that it uses every pattern in
the book. Prefer the simplest thing that keeps the boundaries clean, and add
an abstraction (a base class, a registry, a config knob) only when a second,
real case for it exists — not preemptively.

## Non-negotiable rules

A handful of rules hold everywhere in the codebase, with no exception:

- **Language.** All code, comments, commit messages, and docstrings are in
  English. The one exception is the client's UI strings, which are Italian
  by product decision (see "Client engineering" below) — that is the
  boundary, not a loophole.
- **Money is integer cents, never a float.** Currency is an explicit field
  alongside the amount, never assumed. See `Money` in
  `backend/src/traccio/domain/money.py`.
- **`effective_amount` is derived in one pure function**, in `domain/`, and
  is never mixed with the raw `amount` a bank reported. See
  `architecture.md`.
- **Backend layers point inward** (`domain/` imports nothing; `services/`,
  `providers/`, `db/` import only `domain`; `api/` sits on top) — see
  `architecture.md` for the full table and its two documented exceptions.
- **Detection only suggests, never mutates.** A role, a link between
  transactions, or a confirmed category changes only on an explicit user
  action, never as a side effect of a sync or a background job.
- **Every query is scoped by `user_id`, and sync is idempotent** — no
  exceptions, including an admin or debug path. Traccio is built for one
  user today, but the discipline is what keeps a second one possible later
  without a rewrite.
- **Never log or print sensitive financial data.** See "Data safety" below.

## Backend engineering (Python)

Managed with `uv`; see `CONTRIBUTING.md` for the exact commands. `mypy
--strict` and `ruff` are both authoritative — CI runs both, and a lint isn't
silenced without a reason given at the call site.

### Modularity and boundaries

- **One module, one responsibility.** A file that starts mixing concerns (a
  router that also holds its schema and its SQL) gets split before it
  grows. `db/` (`models/`, `mappers.py`, `repositories/`, `session.py`) and
  `domain/` (`models.py`, `enums.py`, `money.py`) already follow this —
  match it in new code.
- **Respect the layer graph.** If a function needs something from a layer
  above it, the design is wrong — move the function, don't add the import.
  A new module goes in the layer whose rules it can actually satisfy.
- **Push logic into pure functions.** Anything that can be a function of
  its inputs with no I/O should be one — it's the most testable and most
  reusable form. Derivations live in `domain/` as pure functions (see
  `effective_amount`).
- **Depend on arguments, not on globals.** A module that needs a key, a
  clock, or a session takes it as a parameter rather than reaching into
  `core/config`. `core/crypto.py` and `core/logging.py` both take their
  values as arguments so `core/` stays uncoupled; `api/` injects
  request-scoped values with FastAPI's `Depends`. This is dependency
  injection without a framework for it — keep it that way.

### No hardcoding

- **Configuration comes from `Settings`** (`core/config.py`'s
  `get_settings()`), never a literal in the middle of logic. Every setting
  is documented in `backend/.env.example` with a boot-safe default — the
  app must start with no `.env` file present.
- **Name your constants.** A fixed protocol value (an issuer, an audience, a
  default TTL, a base URL) is a module-level constant with a clear name,
  not a magic literal inline.
- **No hardcoded paths, hosts, or secrets** anywhere — paths and hosts are
  config, secrets are never in code, a fixture, or a test.
- **No hidden currency or sign assumptions.** Currency is always explicit; a
  provider's sign convention is normalized in its own adapter, documented
  there, never assumed at a call site.

### Patterns only when they're earned

- **YAGNI.** No abstraction, base class, registry, or config knob for a
  second case that doesn't exist yet. The provider `ABC`
  (`providers/base.py`) is the one deliberate exception — a second Open
  Banking provider is a real, near-term future, so the seam is load-bearing
  today.
- **A function beats a class** until there's state or a substitution seam
  that justifies the class.
- **Use an interface (`ABC`/`Protocol`) at a real boundary** — where a
  caller must not know which implementation it has. The `BankProvider`
  adapters (Strategy pattern) are the one place branching on "which
  provider" is allowed at all.
- **Prefer composition over inheritance.** Inherit to implement an
  interface, not to share code — share code with a plain function.

### Types and contracts

- **Domain and DTO models are Pydantic, with `extra="forbid"`.** Value
  objects that shouldn't change are `frozen=True` (`Money`, the provider
  DTOs) — mutate by constructing a new value, never in place.
- **Make illegal states unrepresentable.** An enum, not a free string; a
  value object, not a bare `int`; `None` only where absence is a real,
  handled case.
- **Secrets are excluded from `repr`** (`Field(repr=False)`), so logging a
  whole settings/model object can't leak one — a type-level defense, not an
  afterthought.

### Errors

- **Raise domain-specific exceptions with stable, value-free messages**, and
  attach a non-sensitive identifier rather than a value —
  `ValueError("invalid encryption key")`, never the key itself.
- **Never re-raise a provider or library exception unchanged** — its
  message may carry a response body. Wrap it; `raise ... from exc`
  preserves the chain for debugging without repeating the detail.
- **Fail loudly and early** where a precondition is genuinely required (an
  unset key at the point of use) rather than limping on and surfacing a
  confusing error deeper down.

### Idiom

- **Standard library first** — `pathlib`, timezone-aware `datetime` (always
  UTC, `datetime.now(UTC)`), `dataclasses`/`enum` before a new dependency. A
  new top-level dependency (a new DB, a task queue, Docker) is flagged as a
  question, not added to solve a problem not yet hit.
- **numpy-style docstrings** on public functions and classes: what and why,
  with a parameter table on any real public seam.
- **Tests exercise the seam, not the implementation.** A `Fake` that
  implements the same interface (see `FakeBankProvider`) proves
  substitutability; inject it rather than patching internals. Fixtures are
  synthetic — see "Data safety" below.

## Client engineering (Swift)

`Packages/TraccioCore` is where logic goes — it builds and tests from the
command line with no Xcode (`swift test`), which is what makes it verifiable
without a simulator. `App/` is presentation only: views, navigation,
platform wiring, thin on logic. A view that starts computing or transforming
data is a sign the logic belongs one layer down, in `TraccioCore`.

**Design direction**: a custom, hand-styled UI (cards, one accent colour,
the system typeface) rather than stock `List`/`Form` styling — see
`decisions/0008-client-design-direction.md` for why, and
`design/tokens.md` for the exact values and their Swift names.

**The backend owns every derived value.** The client never computes a
total, a percentage, or `effective_amount` — it renders what the backend
returned. A missing number is a backend gap, not a client feature to
work around.

**No local read cache.** The client has no offline persistence for
financial data: every screen fetches fresh from the backend. The only two
bits of local state are the server URL and API token (in the Keychain, via
`ServerConfiguration` / `Impostazioni ▸ Server`) and a biometric-lock
preference (`AppLock`, a plain `Bool` in `UserDefaults` — not financial
data, so the restriction below doesn't apply to it). An earlier draft of
this document described a local "read cache" that was never actually built;
if one is added later, it needs its own file-protection and data-safety
review before this paragraph can describe it as real.

**View models depend on `APIClientProtocol`, not the concrete `APIClient`.**
Every one of the client's 14 view models holds `any APIClientProtocol`,
defaulting to `APIClient.current`; a test injects `FakeAPIClient` instead of
stubbing the network. `APIClientProtocol` is a composition of one protocol
per domain (`AccountsAPI`, `EventsAPI`, …), matching how `APIClient` itself
is split into `APIClient+<Domain>.swift` files — a new endpoint touches one
domain's protocol, one implementation extension, and one fake extension,
not a single 60-method interface.

**The client has no notion that bank tokens exist.** They never leave the
backend and are never returned by any endpoint. This is unrelated to the
app's own API token (`ServerConfiguration`) — the client's shared secret for
reaching its own backend.

### Value types and boundaries

- **Prefer `struct` and `enum` over `class`.** Reach for a reference type
  only when identity or shared mutable state is genuinely needed (a view
  model, an actor).
- **Protocols at real seams, not everywhere.** Introduce one where the
  caller must not know the concrete type — the API client is the obvious
  one. Don't add a protocol to abstract a single concrete type with no
  second implementation.
- **Dependency injection over singletons.** Pass collaborators in (an
  initializer parameter with a sensible default); avoid global mutable
  shared state. A testable seam is an injected one.
- **Make illegal states unrepresentable.** Model loading/loaded/empty/failed
  as an enum with associated values (`LoadState<Value>`), not a pile of
  optional `Bool`s. An unknown wire value should fail to decode rather than
  silently become `nil`.

### Concurrency

- **Swift 6 strict concurrency is the floor.** Types crossing concurrency
  boundaries are `Sendable`; build formatters and other helpers locally
  rather than sharing mutable statics.
- **View models are `@MainActor @Observable`** and do only orchestration —
  call the client, publish the outcome. No derivation (see above).
- **No blocking the main thread**; use `async`/`await` and structured
  concurrency. Isolate shared mutable state in an `actor` if it's ever
  needed.

### Safety and no hardcoding

- **No force-unwrap (`!`), no `try!`, no implicitly unwrapped optionals**
  outside test scaffolding. Use `guard let`/`if let`, `??`, and typed
  `throws`.
- **No hardcoded hosts or paths in views.** A base URL or endpoint is
  configuration passed into the client, never a literal buried in a `View`.
- Data safety specifics for the client are in the shared section below.

### Idiom and testability

- **Models are hand-written against `docs/api/openapi.json`**
  (`make openapi`), one per response shape, not generated — each carries a
  decoding test over a representative envelope, including the negative
  cases (an unknown enum value, a malformed timestamp), so a backend rename
  fails a test rather than surfacing as a runtime surprise. A real
  generator (`swift-openapi-generator` or similar) is a deliberate
  non-choice while there are few enough models per slice to hand-maintain —
  revisit if that stops being true.
- **Test the seam, not the implementation.** Inject a fake client
  conforming to the protocol; assert on the published state.
- **`swift test` stays green and Xcode-free.** Keep new logic in
  `TraccioCore` so it stays exercisable from the command line.
- **Small, focused files**, one type or one concern each, mirroring the
  backend's "don't lump" rule.

## Data safety

A leak here is not a bug, it's an incident — when in doubt, log less.

**Never log, print, or put in an error message**: IBANs, full or partial
account numbers, card numbers (even a bank's own masked ones), transaction
amounts or balances, descriptions or merchant names, counterparty names (a
creditor/debtor name identifies a real person), access/refresh tokens,
consent identifiers, authorization codes, or anything taken verbatim from a
provider response body. This applies to `print`, every `logger.*` level
including `debug`, exception messages, assertion messages, and Swift's
`print`/`dump`.

**Never log a whole object** — `logger.info(f"synced {transaction}")` leaks
everything the moment someone adds a field. Log identifiers and counts:

```python
logger.info("sync completed", connection_id=conn.id, imported=42, skipped=3)
```

not

```python
logger.info(f"imported {tx.description} for {tx.amount}")
```

**Exceptions never carry a value.** `ValueError(f"bad amount {amount}")`
puts a real amount into logs and potentially into a client error response.
Raise with a stable message and attach a non-sensitive identifier instead:
`raise InvalidTransaction("amount failed validation", entry_reference=ref)`.
Never re-raise a provider exception unchanged — its message may contain the
response body.

**Tokens** are encrypted at rest with the key held outside the database,
never returned by any endpoint (not even to the owning user), never written
to a file, a fixture, or a test snapshot, and never included in the OpenAPI
schema. If a token needs identifying in a log, log the connection id.

**Test data is always synthetic**: invented IBANs, round amounts,
descriptions like `"TEST MERCHANT 01"`. Never paste a real bank response
into a test file, even redacted — redaction gets missed. The same applies
to anything committed under `docs/`.

**Client-side specifics**: no financial data in `UserDefaults`; bank
authorization runs in the system browser, never an in-app `WebView` (bank
SCA apps often fail to open from one); consider what appears in the app
switcher's snapshot when the app is backgrounded.

When genuinely unsure whether something is safe to log, don't — an omitted
log line costs a few minutes of debugging later; a leaked one may be
unrecoverable, since logs get shipped, backed up, and retained.
