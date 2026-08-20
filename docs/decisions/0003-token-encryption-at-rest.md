# 0003 — Token encryption at rest: Fernet with an env-var key

Status: accepted
Date: 2026-08-20

## Context

Traccio stores the credentials Enable Banking issues after a consent handshake
(the session/consent secret) against each `Connection`, and uses them to sync
without asking the user to re-authorize every time. These are secrets: the
domain glossary and `docs/architecture.md` already require that connection
credentials/tokens are **encrypted at rest with a key held outside the
database**, never logged, and never returned by any endpoint. The backlog gates
this: "Token encryption at rest — decide the scheme before storing anything."

The scheme had to be chosen before the Enable Banking adapter (which persists
the first real credential) is built. Constraints: Traccio is a personal, local,
dependency-light backend managed with `uv` (root `CLAUDE.md`), with no extra
infrastructure and no legal entity before M4. Whatever is chosen must be simple,
testable with no network, and portable across the dev Mac and CI.

## Decision

Encrypt stored credentials with **Fernet** (AES-128-CBC + HMAC-SHA256) from the
`cryptography` library. A **single key is read from the `TRACCIO_ENCRYPTION_KEY`
environment variable**, held outside the database, never logged, never returned
by any endpoint.

- The primitive is `core/crypto.py` (`TokenCipher`, `get_token_cipher`). Like
  `core/logging.py`, it takes the key as a plain argument and does not import
  `core/config`, keeping `core/` decoupled; the caller reads
  `get_settings().encryption_key` and passes it in.
- `encryption_key` is `None` by default so the app still boots with no `.env`
  (the existing config convention). Any operation that touches a stored secret
  requires it to be set; `get_token_cipher(None)` fails loudly rather than
  silently.
- Fernet output is authenticated: a wrong key or a tampered ciphertext raises
  `InvalidToken` instead of returning garbage.

Reasons: Fernet is the standard, well-reviewed high-level recipe in a library
Python teams already trust; it is a few lines to use correctly, needs no new
infrastructure, and is fully testable offline. An env var matches how the rest
of the backend is configured (`TRACCIO_` prefix) and works identically on the
dev Mac and in CI.

## Consequences

- **New top-level dependency**: `cryptography` (added via `uv add`, per the
  rules). Justified as the necessary primitive for encryption the project
  already mandates, not new infrastructure.
- **Key management is the user's responsibility.** Losing the key means every
  stored credential becomes undecryptable and all connections must be
  re-authorized. The key is a secret: gitignored (`.env`), never committed,
  never logged — same handling as the Enable Banking `.pem`.
- **Rotation** is possible later with `MultiFernet` (decrypt under the old key,
  re-encrypt under the new one) without changing the storage format. Not built
  now.
- The `Connection`/`ConnectionRow` credential column and the wiring of this
  cipher into it land with the Enable Banking adapter, not here.

## Alternatives considered

- **Raw AES-256-GCM via `cryptography.hazmat`** — a larger key size but more
  code to assemble nonces and tags correctly, with no practical benefit for
  encrypting short secrets on a single-user local backend. Fernet's authenticated
  construction covers the need with less room for error.
- **Database-level encryption (Postgres `pgcrypto`, SQLCipher)** — couples the
  secret handling to the database, moves the key into DB reach, and complicates
  the SQLite-based local/test path. Rejected: the requirement is "key held
  outside the DB".
- **OS Keychain (macOS)** — more secure at rest on the dev Mac, but macOS-only
  and awkward to reach from a Python backend (needs `keyring` or the `security`
  CLI), which hurts testability and portability. Rejected for now; revisit if
  the deployment model changes.

## Revisit when

- **M4 / going public** — a managed KMS with envelope encryption (per-connection
  data keys wrapped by a KMS master key) becomes appropriate once there are
  multiple users and a legal entity, alongside the other M4 obligations in ADR
  `0002`.
- The deployment stops being a single local process, making an env-var key
  insufficient.
