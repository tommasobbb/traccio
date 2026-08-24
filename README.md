# Traccio

A personal finance tracker: aggregates bank accounts via Open Banking APIs
and categorizes transactions. Two deliverables from one repo — a Python
backend and a native SwiftUI client (iOS + macOS).

Built for one user, on real data, for free. See `tasks/ROADMAP.md` for the
strategy and `docs/architecture.md` for how the pieces fit together.

## Layout

- `backend/` — FastAPI service, Python, managed with `uv`.
- `client/` — SwiftUI app (iOS + macOS), built around a command-line-testable
  `TraccioCore` package.
- `docs/` — architecture, domain glossary, Open Banking provider notes, ADRs.
- `tasks/` — roadmap, backlog, and a log of completed work.

## Getting started

```
make setup   # install backend + client dependencies
make run     # run the backend locally with reload
make test    # backend + client test suites
```

Full command list: `make help`. Start with `CLAUDE.md` for the non-negotiable
project rules, then `backend/CLAUDE.md` / `client/CLAUDE.md` for how each
side is actually built.
