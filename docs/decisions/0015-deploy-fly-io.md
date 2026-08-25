# 0015 — Deploy on Fly.io, not a self-managed VPS

Status: accepted
Date: 2026-08-25

## Context

Item 7 of the iPhone-trial roadmap (`tasks/backlog.md`) was the last
uncrossed blocker before a real phone could reach the backend: `make run`
binds uvicorn's default loopback only, there was no Postgres anywhere but a
local dev SQLite file, and no TLS, process supervision, or deploy artifact
existed. The roadmap's original plan named "a small always-on VPS" as the
hosting choice. Asked directly during this task, the user proposed Fly.io
instead.

## Decision

**Fly.io**, not a self-managed VPS. It replaces three separate manual setup
steps (buy a domain, install/renew a TLS cert, write a systemd unit) with
configuration: a domain is included per app (`<your-app>.fly.dev`), TLS is
automatic, and `min_machines_running` plus Fly's own health checks are the
supervision. `fly postgres create` replaces installing and hardening
Postgres by hand. At the account's smallest paid tier — one
`shared-cpu-1x`/256MB machine plus a matching Postgres machine and a 1GB
volume — the running cost is close to a comparable VPS (~4 $/month), not
free: Fly closed its no-card free allowance in October 2024, corrected
mid-conversation after the user assumed otherwise.

This is a deliberate exception to the root `CLAUDE.md`'s "don't add a new
top-level dependency (a new DB, a task queue, **Docker**) to solve a problem
you haven't hit yet" — the problem this closes (`tasks/backlog.md`'s "the
client cannot reach the backend from a real device") is real and already
hit, and Fly's deploy unit *is* a container; there was no lighter path to
"reachable from a phone, real Postgres, TLS" available.

### What shipped

- **`backend/Dockerfile`**: multi-stage, `python:3.13-slim` + `uv` (the
  official `ghcr.io/astral-sh/uv` image supplies the binary in the builder
  stage only — the runtime stage never has `uv` itself, just the venv `uv
  sync` produced). Runs as a non-root `traccio` user. `backend/.dockerignore`
  excludes `tests/`, `.venv/`, `*.db`, `.env*`, `.certs/`, and the dev-only
  `scripts/` — none of the local-dev cruft crosses into the image.
- **`backend/fly.toml`**: `primary_region = "fra"` — Fly has **no Italy
  region**; the option list is Amsterdam/Frankfurt/London/Paris/Stockholm,
  and Frankfurt is the closest, most established European hub (also
  corrected mid-conversation — the plan had assumed an `mxp` region that
  does not exist). `min_machines_running = 1`, not Fly's zero-machine
  default: the in-process background sync scheduler (ADR 0010) only runs
  while a machine is up, so auto-stop would silently kill it between
  requests. `[deploy].release_command = "python -m alembic upgrade head"`
  runs migrations once, before traffic switches to the new machine — the
  same principle as the Makefile's `db-upgrade` prerequisite (never inside
  the running app process), applied to the Fly deploy lifecycle instead of
  a local `make` target.
- **One machine, not two.** `fly deploy` defaults to launching a second
  machine "for high availability and zero-downtime deployments" the moment
  `min_machines_running >= 1`. Scaled back to `fly scale count 1`
  immediately: two machines would double the monthly cost for a
  single-user app, and would run ADR 0010's background scheduler twice —
  synchronizing the same connections from two processes at once. Sync is
  idempotent (root `CLAUDE.md`), so this would not have corrupted data, but
  it would have burned each bank's rate-limit budget twice as fast for no
  benefit. `fly scale show` confirms the count persists across future
  deploys.
- **`Settings.enable_banking_private_key_pem`** (`core/config.py`,
  `api/deps.py::get_bank_provider`): a new setting holding the RSA private
  key's PEM content directly, alongside the existing
  `enable_banking_private_key_path`. Fly secrets are environment variables,
  not files — the key can't sit at a filesystem path the way local dev's
  `.pem` file does. `get_bank_provider` prefers the PEM-content setting when
  both are present; local dev is unaffected since it only ever sets the
  path. Documented in `.env.example`.
- **Secrets, all via `fly secrets set`, none in the tracked `fly.toml`**:
  `TRACCIO_DATABASE_URL` (rewritten from `fly postgres attach`'s default
  `postgres://` scheme to `postgresql+psycopg://` — SQLAlchemy's psycopg3
  driver needs the driver-qualified scheme; the plain `DATABASE_URL` Fly
  would otherwise set was left unset), `TRACCIO_ENCRYPTION_KEY` and
  `TRACCIO_API_TOKEN` (freshly generated for production, distinct from the
  dev-only values in the local `.env` — no reason to share a secret between
  a laptop and a public endpoint), `TRACCIO_ENABLE_BANKING_APPLICATION_ID`
  and `TRACCIO_ENABLE_BANKING_PRIVATE_KEY_PEM` (the same Enable Banking
  application as local dev — a second application registration was not
  needed). `TRACCIO_ENABLE_BANKING_REDIRECT_URL` is the one non-secret
  value and lives in `fly.toml`'s tracked `[env]`, pointing at
  `https://<your-app>.fly.dev/connections/callback`.
- **Verified**: `alembic upgrade head` via `release_command` ran clean
  against real Postgres on the first deploy — the first time any of the 16
  migrations have run outside SQLite, closing the M0 backlog item open
  since the project's start ("Verify the initial migration on a real
  PostgreSQL"). `GET /health` returns `200` unauthenticated;
  `GET /accounts` returns `401` with no token or the wrong one, `200` with
  the real production token — `require_api_token` (ADR 0014) behaves
  identically to local dev. `make lint`/`make test` (512 backend tests)
  stayed green through the two-line `config.py`/`deps.py` change.

## Consequences

- **Not done in this slice, both real user actions, not automatable:**
  - The Enable Banking Control Panel still lists the old
    `https://localhost:8000/connections/callback` redirect — a real
    consent flow against the production backend will fail until the new
    `https://<your-app>.fly.dev/connections/callback` is registered
    there too (`api/deps.py`'s own docstring: the redirect "must match
    both" the Control Panel and the callback endpoint).
  - **Universal Link consent callback** (the client returning to the app
    automatically after SCA, rather than the user switching back by hand)
    needs an Apple Team ID for `apple-app-site-association` and
    `client/Project.yml`'s `associated-domains` entitlement — blocked on
    the still-pending Apple Developer membership. Until then, the browser
    redirect works, just without the automatic app return.
- **Data migration is an open, deliberately unmade choice.** The production
  Postgres is empty — no accounts, no synced transactions, no
  categorizations. Bringing over the real history already synced into the
  local `dev.db` (3 accounts, hundreds of transactions, months of manual
  categorization) versus re-syncing everything fresh from each bank is a
  separate decision for whenever daily use actually starts, not made here.
- The client's Impostazioni ▸ Server (ADR 0014's client revision) still
  needs pointing at `https://<your-app>.fly.dev` with the new production
  token — the app's zero-config default remains `http://localhost:8000`,
  so nothing changes until the user does this by hand.
- `TRACCIO_BACKGROUND_SYNC_ENABLED` was left unset (`false`, the existing
  default) on the deployed app. Turning it on is a separate decision, not
  bundled into standing the infrastructure up.

## Alternatives considered

- **A self-managed VPS (Hetzner/OVH) + a bought domain.** The roadmap's
  original plan. More manual setup (TLS renewal, systemd, Postgres
  hardening) for a comparable monthly cost and no meaningful advantage for
  a single-user personal app.
- **Two machines (Fly's deploy default).** Rejected — see "One machine, not
  two" above.
- **Reusing the local dev `TRACCIO_ENCRYPTION_KEY`/Enable Banking
  registration for production.** Rejected for the encryption key (fresh
  secret per environment is the safer default, and the production database
  starts empty regardless — there is nothing yet to decrypt with the old
  key). The Enable Banking application id/key *were* reused: registering a
  second Enable Banking application for the same personal use case would
  have been pure overhead.

## Revisit when

- The Apple Developer membership lands — wire the Universal Link callback
  described above.
- The data-migration choice above actually needs making, i.e. right before
  daily use starts for real.
- `TRACCIO_BACKGROUND_SYNC_ENABLED` gets turned on for the deployed app —
  re-confirm `min_machines_running = 1`/`fly scale count 1` still holds, so
  the scheduler still runs exactly once.
