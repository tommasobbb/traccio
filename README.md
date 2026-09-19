# Traccio

A personal finance tracker: aggregates bank accounts via Open Banking APIs
and categorizes transactions. Two deliverables from one repo — a Python
backend and a native SwiftUI client (iOS + macOS).

Built for one user, on real data. See `docs/architecture.md` for how the
pieces fit together and `docs/domain.md` for the shared vocabulary.

> **This is a single-user, personal tool, not a production multi-tenant
> service.** There is one fixed user id, one shared API bearer token
> instead of real per-account authentication, and no rate limiting beyond
> what the Open Banking provider itself enforces. It's built this way on
> purpose (see `docs/decisions/0002-personal-first.md` and
> `docs/decisions/0014-api-token.md`) — don't deploy it as a multi-user
> service without addressing that first.
>
> **The client's UI is Italian-only**, by product decision — there is no
> localization table to switch. Everything else (code, comments, docs) is
> English.

## Layout

- `backend/` — FastAPI service, Python, managed with `uv`.
- `client/` — SwiftUI app (iOS + macOS), built around a command-line-testable
  `TraccioCore` package.
- `docs/` — architecture, domain glossary, Open Banking provider notes,
  engineering conventions, and a full history of design decisions
  (`docs/decisions/`).

## Getting started

Prerequisites: [`uv`](https://docs.astral.sh/uv/) for the backend; Xcode 26+
and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the client (see
`CONTRIBUTING.md` for exact versions). PostgreSQL is **not** required — the
default configuration uses a local SQLite file.

```
git clone <this repo>
cd traccio
make setup                              # install backend + client dependencies
cp backend/.env.example backend/.env    # SQLite by default; nothing to edit
make demo                                # populate a full synthetic dataset
make run                                 # backend on http://localhost:8000
```

At this point `GET http://localhost:8000/health` responds and
`GET /dashboard/summary` returns real (synthetic) numbers — a few months of
categorized transactions across four accounts, an event, a partially
reimbursed advance, and a transfer pair waiting to be detected. No bank
credentials involved.

To run the client: `make xcode` generates `client/Traccio.xcodeproj` from
`client/Project.yml` (edit the `.yml`, never the generated project — it's
gitignored). Open it in Xcode and run the `App` scheme against a simulator
or your own Mac. Its default server configuration
(`Impostazioni ▸ Server` inside the app) already points at
`http://localhost:8000`, matching `make run` above — nothing else to
configure for the demo data to show up. (The app's `Info.plist` allows
plaintext local networking for exactly this reason —
`NSAllowsLocalNetworking`, `client/Project.yml` — never for a non-localhost
endpoint.)

To connect a **real** bank account instead of the synthetic demo data, see
`docs/setup-openbanking.md` — it walks through registering an Enable
Banking application, generating the RSA key pair, and running the local
HTTPS callback the bank redirects to after authorization.

```
make test    # backend + client test suites (make test-app needs Xcode separately)
make lint    # ruff + mypy on the backend
```

Full command list: `make help`. For the development workflow (adding an
endpoint, adding a client feature, code style) see `CONTRIBUTING.md`; for
the engineering conventions behind that workflow, see
`docs/engineering.md`.
