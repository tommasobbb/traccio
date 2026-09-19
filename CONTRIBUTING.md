# Contributing

Traccio is a personal project, built and used by one person — this is not a
heavyweight open-source process, just enough structure to keep the code easy
to come back to. This document covers the development workflow: setup,
commands, tests, and how to add something new. For *why* the code is
structured the way it is, see `docs/architecture.md` (the shape of the
system) and `docs/engineering.md` (the conventions below the architecture).
`docs/domain.md` is the shared vocabulary — read it before touching anything
that talks about money, accounts, or transactions.

## Prerequisites

- **Backend**: Python managed by [`uv`](https://docs.astral.sh/uv/) — install
  `uv` itself, nothing else; `uv` manages the Python version and every
  dependency. PostgreSQL is optional: the default configuration uses a local
  SQLite file, so there is nothing else to install for backend development.
- **Client**: Xcode 26 or later (the project targets iOS 26 / macOS 26 — see
  `docs/decisions/0030-liquid-glass-chrome.md`), plus
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
  The Swift 6 toolchain ships with Xcode; nothing else is needed to run
  `swift test` on `TraccioCore` from the command line.

## Setup

```
git clone <this repo>
cd traccio
make setup                              # installs backend + client dependencies
cp backend/.env.example backend/.env    # SQLite by default, nothing to edit for local dev
make demo                                # populates a full synthetic dataset
make run                                 # backend on http://localhost:8000
```

Then, for the client: `make xcode` generates `Traccio.xcodeproj` from
`client/Project.yml` (never edit the generated project directly, and never
commit it — it's gitignored on purpose). Open it in Xcode and run the `App`
scheme against a simulator or your own Mac; the default server configuration
points at `http://localhost:8000`, matching `make run` above.

See the root `README.md` for the full quickstart, including connecting a
real bank account.

### Troubleshooting: `ModuleNotFoundError: No module named 'traccio'`

Create the backend venv **only** with `uv venv` (what `make setup` /
`make reset-venv` do). The `virtualenv` tool seeds a `_virtualenv.pth` that
interferes with the editable install's own `src` path entry the moment
`site.py` imports it — this is the symptom if you ever hit it by creating
the venv some other way. `make reset-venv` recreates it from scratch. Test
imports are already immune to this (`pythonpath = ["src"]` in
`pyproject.toml`'s pytest config puts `src` on `sys.path` directly), so this
only matters for a non-pytest path like `make run`.

## Commands

Run all of these from the repo root.

| Command         | What it does                                                     |
| ---------------- | ----------------------------------------------------------------- |
| `make setup`     | Install backend + client dependencies                             |
| `make run`       | Run the backend locally with reload                               |
| `make demo`      | Populate the DB with a full synthetic dataset (SQLite, no setup)   |
| `make test`      | Run backend + client test suites (`test-backend` + `test-core`)   |
| `make test-app`  | Run the client's `App/` view-model tests (needs Xcode)             |
| `make lint`      | Ruff + mypy on the backend                                         |
| `make fmt`       | Auto-format the backend                                            |
| `make xcode`     | Regenerate `Traccio.xcodeproj` from `Project.yml`                  |
| `make openapi`   | Export the OpenAPI schema the client's models are hand-written against |

Full list, with one-line descriptions: `make help`.

**Single test, backend:**

```
cd backend && uv run pytest tests/test_foo.py::test_bar
```

**Single test, Swift package:**

```
cd client/Packages/TraccioCore && swift test --filter TraccioCoreTests.FooTests/testBar
```

## Before you start something bigger than a one-line fix

- Check `tasks/ROADMAP.md`/`tasks/backlog.md` if they exist in your checkout
  — they're a personal working log and gitignored, so a fresh clone won't
  have them; skip this if so.
- If a change touches both `backend/` and `client/`, say so (in the PR
  description, or to yourself in the commit message) rather than discovering
  it midway — the two sides evolve independently on purpose (see
  `docs/architecture.md`, "The backend owns every decision").
- An architectural decision worth remembering later goes in
  `docs/decisions/NNNN-title.md` (copy the format from an existing one, e.g.
  `0008`), not just in a commit message. Small conventions and craft-level
  rules go in `docs/engineering.md` instead of a new ADR.

## Adding a backend endpoint

1. **Schema** in `backend/src/traccio/api/schemas/<resource>.py` — Pydantic
   models for the request/response bodies, `extra="forbid"`.
2. **Repository function(s)** in `backend/src/traccio/db/repositories/<resource>.py`
   if the endpoint needs new persistence logic — scoped by `user_id`, using
   the domain models and the mappers in `db/mappers.py`.
3. **Router** in `backend/src/traccio/api/routers/<resource>.py` — an
   `APIRouter`, wired into `api/main.py`'s `create_app()`. Request-scoped
   values (the current user id) come through a FastAPI `Depends` in
   `api/deps.py`, not a closure.
4. **Test** in `backend/tests/` exercising the endpoint through FastAPI's
   `TestClient`, with a real (SQLite) database — see an existing
   `test_*_endpoint.py` for the fixture pattern.
5. `make openapi` to regenerate `docs/api/openapi.json`, then hand-write the
   matching Swift model(s) in `TraccioCore` if the client needs the new
   shape (see below).

`make lint` and `make test-backend` should both stay green throughout —
`mypy --strict` catches most integration mistakes (a wrong field name, a
missing import) before a test even runs.

## Adding a client feature

1. **Model** (if the wire shape is new): a hand-written `Codable` struct in
   `TraccioCore`, matching `docs/api/openapi.json`, with a decoding test
   covering at least one negative case (an unknown enum value or a
   malformed field) — see `docs/engineering.md`'s client section for why
   this is hand-written rather than generated.
2. **API client method**: add it to the relevant `APIClient+<Domain>.swift`
   extension and its matching `<Domain>API` protocol; add a matching case to
   `FakeAPIClient+<Domain>.swift` for tests.
3. **View model**: a `@MainActor @Observable` class depending on
   `any APIClientProtocol` (defaulting to `APIClient.current`), holding
   state as an enum (`LoadState<Value>` for the common load/loaded/failed
   shape) rather than a pile of optional `Bool`s. No derived values here —
   if a number needs deriving, that's a backend gap, not a client feature.
4. **View**: presentation only, in `App/Sources/`. Reach for the existing
   design-system components (`Card`, `IconTile`, `SelectionSheet`, …,
   documented in `docs/design/tokens.md`) before hand-rolling a new one.
5. **Tests**: a view-model test in `App/Tests/` against `FakeAPIClient`
   (`make test-app`, needs Xcode), plus whatever `TraccioCoreTests` cases the
   new model or logic needs (`make test-core`, does not need Xcode).

## Style

- Ruff and mypy are authoritative for the backend (`make lint`); don't
  silence a lint without a reason given at the call site. `make fmt` before
  committing.
- No equivalent linter enforces the Swift conventions in
  `docs/engineering.md` today — following them is a matter of review, not
  tooling, until that changes.
- Commit messages and everything in a file are English; the client's UI
  strings are the one deliberate exception (Italian, by product decision —
  see `docs/engineering.md`).

## Reporting an issue / proposing a change

This is a single-maintainer personal project without a support commitment,
but issues and pull requests are welcome — open one on GitHub. Security
issues (anything touching bank credentials, tokens, or the auth boundary)
are best reported privately first.
