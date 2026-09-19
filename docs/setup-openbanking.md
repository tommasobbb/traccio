# Setting up a real bank connection

A step-by-step walkthrough for connecting a real bank account through
Enable Banking, the Open Banking provider Traccio uses
(`docs/decisions/0001-aggregator-choice.md`). Skip this entirely if you just
want to look around — `make demo` populates a full synthetic dataset with no
bank credentials at all.

This is the "how", written once, for a first-time setup. `docs/openbanking.md`
is the deeper operational reference — provider quirks, per-bank findings,
rate-limit constraints — read it before changing anything under
`backend/src/traccio/providers/`.

## 1. Create an Enable Banking account

Go to <https://enablebanking.com/sign-in/> and enter your email. The
account is created on first sign-in via a magic link — there is no
password.

## 2. Register an application

In the Control Panel, under **API applications**:

- **(Recommended first) A Sandbox application.** Choose the **Sandbox**
  environment, give it a name (shown to you during the bank's authorization
  screen), and provide at least one **redirect URL** — for local development,
  `https://localhost:8000/connections/callback` (matching
  `TRACCIO_ENABLE_BANKING_REDIRECT_URL`'s default in `backend/.env.example`).
  Submitting downloads a **private RSA key**, `<application-id>.pem`. Sandbox
  lets you exercise the whole flow against Enable Banking's test banks before
  touching a real account.
- **A Production application**, the same way, choosing **Production**
  instead. It starts **Inactive** and downloads its own `<application-id>.pem`.
  Activating it (next step) is what actually lets it reach real banks, in
  **restricted production** mode — it can only ever read the specific
  accounts you personally authorize, no contract or KYB required (see
  `docs/decisions/0002-personal-first.md` for why this mode is enough for a
  personal tool).

Either way, note the **application id** shown in the Control Panel — it's
not a secret, but the backend needs it.

## 3. Configure the backend

In `backend/.env` (copied from `.env.example` if you haven't already):

```
TRACCIO_ENABLE_BANKING_APPLICATION_ID=<the application id from step 2>
TRACCIO_ENABLE_BANKING_PRIVATE_KEY_PATH=/absolute/path/to/<application-id>.pem
```

Keep the `.pem` file **outside the repo** — `*.pem` is gitignored, but don't
rely on that; treat it like any other credential. Leave
`TRACCIO_ENABLE_BANKING_BASE_URL` at its default (production API host) for
both sandbox and production applications — the application id is what
Enable Banking uses to tell them apart, not the URL.

You'll also need an encryption key, since a successful connection's session
credential is encrypted at rest (`docs/decisions/0003-token-encryption-at-rest.md`):

```
TRACCIO_ENCRYPTION_KEY=$(python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
```

## 4. Run over local HTTPS

The bank redirects back to `TRACCIO_ENABLE_BANKING_REDIRECT_URL` after
authorization, and Enable Banking requires that URL to be `https://` — even
for `localhost` (an `http://` redirect is rejected at registration time).
Use `make run-tls` instead of `make run`:

```
make run-tls
```

The first run generates a self-signed certificate under `backend/.certs/`
(gitignored) and serves the backend over `https://localhost:8000`. Your
browser will warn about the self-signed cert on the callback redirect —
that's expected for local development, not a sign anything is wrong.

## 5. Activate the application by linking your own account (production only)

Back in the Control Panel, use **"Activate by linking accounts"** on your
Production application and complete the bank's SCA (Strong Customer
Authentication) flow for your own account. Once confirmed, the application
moves from **Inactive** to **active in restricted mode** — data retrieval is
limited to whichever accounts you linked this way. A Sandbox application
needs no such activation; it works against Enable Banking's test banks
immediately.

## 6. Connect an account from the app

With the backend running (`make run-tls`) and the client pointed at it
(`Impostazioni ▸ Server`, matching whichever host/port you're running on),
use **"Collega un nuovo conto"**. This opens the bank's authorization page
in the **system browser** (never an in-app WebView — some banks' SCA flows
refuse to open from one). After you approve, the browser is redirected back
to the callback URL, and the connection appears in **Conti**.

The first sync after authorization pulls a generous history window (about
two years, `TRACCIO_INITIAL_HISTORY_DAYS`) — this is a one-shot opportunity,
since the post-authorization window a bank serves full history for is short
and does not repeat. Every sync after that is incremental.

## Notes

- **Consent lifetime.** Enable Banking consents expire (commonly after 90
  or 180 days, bank-dependent); the client surfaces an "expiring soon"
  warning ahead of that (`TRACCIO_CONSENT_WARNING_WINDOW_DAYS`) — see
  `docs/openbanking.md`'s "Operational constraints" for the exact mechanics.
- **Background sync is off by default** (`TRACCIO_BACKGROUND_SYNC_ENABLED=false`)
  — turning it on calls your bank on a schedule rather than only when you
  open the app. It's a deliberate opt-in, not a boot-time surprise.
- **On-device (a real iPhone, not a simulator) is a separate setup step**,
  deferred past this walkthrough: `localhost` doesn't reach your Mac's
  backend from a physical phone, so that needs either an Apple Universal
  Link or a backend reachable over the network (see `backend/fly.toml.example`
  for a hosted option, and `docs/openbanking.md`'s "Redirect URL" section for
  the constraint that shapes it).
- **Sandbox vs. production**: a Sandbox application never touches a real
  bank — useful for exercising the whole consent flow risk-free before
  pointing the same setup at a Production application and your own account.
