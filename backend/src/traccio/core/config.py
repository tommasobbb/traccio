"""Application configuration, loaded from the environment.

``core/`` imports nothing from the rest of the project (see
``docs/architecture.md``); this module depends only on the standard library and
pydantic-settings.
"""

from functools import lru_cache
from uuid import UUID

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Settings read from environment variables (prefix ``TRACCIO_``).

    Values come from, in order of precedence, the process environment and a
    local ``.env`` file. Defaults are chosen so the app boots with no ``.env``
    present; a committable ``.env.example`` documents every variable. Read
    settings through :func:`get_settings`, not by instantiating this directly.

    Attributes
    ----------
    environment : str
        Deployment environment, e.g. ``"development"`` or ``"production"``.
    log_level : str
        Minimum log level name passed to structlog (e.g. ``"INFO"``).
    log_json : bool
        Emit JSON logs (production) when ``True``, human-readable console
        output (development) when ``False``.
    database_url : str
        PostgreSQL DSN. Declared now but unused until persistence lands; kept
        here so ``.env.example`` stays a complete reference.
    dev_user_id : UUID
        Stand-in for the authenticated user until real auth lands (blocked on
        the M4 decision). Traccio is built for one user, so every request is
        scoped to this fixed id. Endpoints stay written as ``scoped by
        user_id``; only where the id comes from changes when auth arrives.
    encryption_key : str or None
        Fernet key for encrypting stored bank credentials at rest (see
        ``docs/decisions/0003-token-encryption-at-rest.md``). Held outside the
        database, never logged. ``None`` by default so the app boots without a
        ``.env``; operations that touch stored secrets require it to be set (see
        :func:`traccio.core.crypto.get_token_cipher`).
    enable_banking_application_id : str or None
        Enable Banking application ID, used as the JWT ``kid`` header when
        authenticating API calls (``docs/openbanking.md``). Not a secret. ``None``
        until configured.
    enable_banking_private_key_path : str or None
        Filesystem path to the application's ``<application-id>.pem`` RSA private
        key. The key is a secret held **outside the database** and never
        committed or logged; only its path lives here. ``None`` until configured.
    enable_banking_base_url : str
        Base URL of the Enable Banking API. Defaults to the production host.
    enable_banking_redirect_url : str
        Whitelisted URL the bank returns the user to after SCA. Must match both
        the redirect registered in the Enable Banking Control Panel and the
        backend callback endpoint (``GET /connections/callback``).
    initial_history_days : int
        How far back a connection's *first* sync requests transactions. The
        post-authorization window a bank serves full history for is short and
        does not come back (``docs/openbanking.md``: "there is no second
        attempt"), so this is deliberately generous. Every later sync uses
        :attr:`sync_overlap_days` instead — see ``services/sync.py``.
    sync_overlap_days : int
        How far before a connection's ``last_synced_at`` an *incremental*
        sync (every sync after the first) re-requests transactions, to absorb
        entries a bank records with a retroactive date. Free to be generous:
        ``upsert_transaction`` is idempotent on stable identity, so
        re-fetching the same window duplicates nothing.
    transfer_amount_tolerance_cents : int
        Maximum absolute difference, in minor units, between the two legs of a
        suggested transfer. Absorbs fees on same-currency internal moves (see
        ``docs/domain.md``). Detection only suggests; nothing is linked
        automatically.
    transfer_window_days : int
        Maximum whole-day gap between the two legs of a suggested transfer;
        settlement is not simultaneous.
    consent_warning_window_days : int
        How many whole days before a consent's ``expires_at`` it is surfaced as
        ``expiring_soon`` (see ``domain/consent.py::consent_state``) rather than
        ``active``. Expiry is a first-class product concern
        (``docs/openbanking.md``): the client warns before a consent lapses,
        because an expired one silently stops producing data.
    pending_transaction_ttl_days : int
        How many days a ``pending`` transaction may go unseen by a sync before
        ``POST /transactions/prune-pending`` considers it abandoned
        (``db/repositories.py::prune_stale_pending_transactions``,
        ``docs/domain.md``: "pending transactions that neither settle nor
        reappear within a defined window are dropped"). Chosen conservatively:
        card authorization holds can legitimately sit for weeks depending on
        merchant category.
    """

    model_config = SettingsConfigDict(
        # Load a local .env if present, namespace every variable under
        # TRACCIO_, and ignore unrelated environment entries.
        env_file=".env",
        env_prefix="TRACCIO_",
        extra="ignore",
    )

    environment: str = "development"
    log_level: str = "INFO"
    # JSON logs in production, human-readable console output in development.
    log_json: bool = False
    # Declared now, unused until persistence lands; keeps .env.example useful.
    database_url: str = "postgresql+psycopg://localhost/traccio"
    # Fixed single-user id until real auth (M4). See the class docstring.
    dev_user_id: UUID = UUID("00000000-0000-0000-0000-000000000001")
    # Fernet key for encrypting stored bank credentials; None until set so the
    # app still boots with no .env. Never logged. See core/crypto.py and ADR 0003.
    encryption_key: str | None = None
    # Enable Banking credentials. The application id is the JWT kid (not secret);
    # the private key is a secret file held outside the DB — only its path lives
    # here, never logged. Both None until configured. See docs/openbanking.md.
    enable_banking_application_id: str | None = None
    enable_banking_private_key_path: str | None = None
    enable_banking_base_url: str = "https://api.enablebanking.com"
    # Must match the redirect registered in the Control Panel and the callback
    # endpoint. https is mandatory; localhost is accepted (docs/openbanking.md).
    enable_banking_redirect_url: str = "https://localhost:8000/connections/callback"
    # Greedy lookback for the initial history fetch (the ~1h post-auth window is
    # the only shot at full history). Dedup makes re-fetching harmless. ~2 years.
    initial_history_days: int = 730
    # How far before last_synced_at an incremental (non-first) sync re-requests,
    # to absorb retroactively dated entries. Free: dedup makes it harmless.
    sync_overlap_days: int = 7
    # Transfer detection tolerances (suggestions only, never auto-linked). A
    # small amount tolerance absorbs fees; a few days absorbs non-simultaneous
    # settlement. See docs/domain.md and services/transfers.py.
    transfer_amount_tolerance_cents: int = 100
    transfer_window_days: int = 4
    # How many days before expiry a consent is surfaced as "expiring soon".
    # See domain/consent.py and docs/openbanking.md's expiry-warning constraint.
    consent_warning_window_days: int = 14
    # How many days a pending transaction may go unseen by a sync before it is
    # considered abandoned. See db/repositories.py::prune_stale_pending_transactions.
    pending_transaction_ttl_days: int = 30


@lru_cache
def get_settings() -> Settings:
    """Return the process-wide settings, loaded once.

    The ``lru_cache`` makes this a lazy singleton: the environment is read on
    the first call and the same :class:`Settings` instance is returned
    thereafter.

    Returns
    -------
    Settings
        The cached, process-wide settings instance.
    """
    return Settings()
