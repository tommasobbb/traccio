"""Application configuration, loaded from the environment.

``core/`` imports nothing from the rest of the project (see
``docs/architecture.md``); this module depends only on the standard library and
pydantic-settings.
"""

from functools import lru_cache
from uuid import UUID

from pydantic import Field, field_validator
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
        SQLAlchemy database DSN. Defaults to a local SQLite file so the app
        boots with no server to install or run — a real deployment (Fly.io,
        ``docs/decisions/0015-deploy-fly-io.md``) points this at PostgreSQL
        instead via an env var, never by changing this default.
    db_pool_size : int
        Persistent connections the app engine's pool keeps open
        (``db/session.py``). SQLAlchemy's own default is 5; named here so a
        deployment on a small managed Postgres can lower it. Ignored by the
        SQLite pool the tests build.
    db_max_overflow : int
        Extra connections the pool may open beyond :attr:`db_pool_size` under
        load, closed again when returned. SQLAlchemy's default is 10.
    db_pool_pre_ping : bool
        Check a pooled connection with a lightweight round-trip on checkout and
        transparently replace it if the server or a proxy dropped it while
        idle. ``True`` by default — one cheap query per checkout in exchange
        for not surfacing a stale-connection error to a request.
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
        Ignored when :attr:`enable_banking_private_key_pem` is set.
    enable_banking_private_key_pem : str or None
        The RSA private key's PEM content directly, for a deployment with no
        writable filesystem to hold a key file (Fly.io: injected as a secret
        env var, ``docs/decisions/0015-deploy-fly-io.md``). Takes precedence
        over :attr:`enable_banking_private_key_path` when both are set. Never
        logged.
    enable_banking_base_url : str
        Base URL of the Enable Banking API. Defaults to the production host.
    enable_banking_redirect_url : str
        Whitelisted URL the bank returns the user to after SCA. Must match both
        the redirect registered in the Enable Banking Control Panel and the
        backend callback endpoint (``GET /connections/callback``).
    default_institution_country : str
        ISO 3166-1 alpha-2 country assumed when a request or a stored
        connection does not carry one. Traccio is single-user and Italy-only
        for now (the client sends ``"IT"`` and ``POST /connections`` already
        defaults its ``country`` query param to it); naming it here keeps that
        assumption in one place instead of a literal in a handler. Used by the
        logo backfill to look up institutions for connections that predate the
        ``country`` column.
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
        settlement is not simultaneous. Reused for funded-payment suggestions.
    funding_amount_tolerance_cents : int
        Maximum absolute difference, in minor units, between the two legs of a
        suggested *funded payment* (``TransferKind.FUNDED_PAYMENT``). A
        card-funded wallet payment is charged at exactly the payment amount —
        there is no fee or FX drift between the legs — so this defaults to
        ``0`` (exact match). A user may still confirm a looser pair explicitly;
        this only bounds automatic suggestions.
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
    import_max_bytes : int
        Largest file ``POST /imports/preview`` and ``/imports/commit`` (ADR
        0023) will decode, in bytes; a larger upload is a ``413``. A monthly
        personal export is a few KB — the default (2 MiB) is headroom that
        still bounds the base64 request body.
    background_sync_enabled : bool
        Whether ``api/main.py``'s lifespan starts the background scheduler
        (``services/scheduler.py``, ADR 0010). ``False`` by default: the app
        must boot with no ``.env`` (``docs/engineering.md``) without silently
        calling a real bank on startup — this is switched on deliberately.
    background_sync_interval_minutes : int
        Minutes between the end of one scheduler tick and the start of the
        next.
    background_sync_budget_per_day : int
        Maximum sync runs (any outcome) per connection per rolling 24h — the
        hard per-consent background fetch budget most banks enforce
        (``docs/openbanking.md``: "~4 background fetches per day"), read as
        *runs*, not raw provider HTTP calls (see
        ``db/repositories.py::count_recent_sync_runs``).
    sync_min_interval_hours : int
        Minimum whole hours between two syncs of the same connection, so a
        sync moments ago (user-triggered or background) is not immediately
        repeated even with budget left.
    send_psu_headers : bool
        Whether ``EnableBankingProvider`` actually attaches PSU-present
        headers to a user-present data-retrieval call (ADR 0011).
        ``False`` by default: the header set this codebase can honestly send
        is incomplete (no real device IP or geolocation is available while
        the client only reaches the backend from localhost —
        ``tasks/backlog.md``), and a bank whose ``required_psu_headers``
        needs one of the missing ones refuses with
        ``PSU_HEADER_NOT_PROVIDED`` regardless. Built and tested, deliberately
        not turned on.
    api_token : str or None
        Shared bearer secret gating every request except ``GET /health`` and
        ``GET /connections/callback`` (``api/deps.py::require_api_token``,
        ADR 0014). ``None`` by default so the app keeps booting with no
        ``.env`` and every existing test keeps passing unauthenticated; set
        this only for a deployment reachable from outside localhost — see
        the ADR for why a shared token rather than real per-user auth.
    fx_enabled : bool
        Whether ``GET /dashboard/summary`` computes the opt-in converted
        combined total (ADR 0021). ``False`` by default: the app must boot
        with no ``.env`` without ever calling an external rate API — turning
        this on is a deliberate step, exactly like
        :attr:`background_sync_enabled`. With it off, ``converted`` in the
        response is always ``null`` and nothing else changes.
    fx_base_currency : str
        ISO 4217 code the converted total is expressed in (ADR 0021). There
        is no per-user preference store yet and the user has one realistic
        base; a ``convert_to`` query param or a preferences table is the
        later move (see the ADR's "Revisit when").
    fx_api_base_url : str
        Base URL of the frankfurter.dev rate API (ECB reference rates, free,
        no key). A setting so a self-hosted instance can be pointed at
        without a code change; not a secret.
    fx_rate_ttl_hours : int
        How stale the row for the most recent ECB date may be before
        ``services/fx.py`` re-fetches it. Historical rows are immutable once
        fetched and are never refreshed regardless of this value.
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
    # SQLite by default so the app boots with nothing to install; point this at
    # PostgreSQL (e.g. postgresql+psycopg://localhost/traccio) for production.
    database_url: str = "sqlite:///./dev.db"
    # Connection-pool sizing for the app engine (db/session.py). Defaults match
    # SQLAlchemy's own; raise or lower per deployment without a code change.
    # pool_pre_ping trades one lightweight query per checkout for immunity to a
    # connection the server/proxy dropped while idle.
    db_pool_size: int = 5
    db_max_overflow: int = 10
    db_pool_pre_ping: bool = True
    # Fixed single-user id until real auth (M4). See the class docstring.
    dev_user_id: UUID = UUID("00000000-0000-0000-0000-000000000001")
    # Fernet key for encrypting stored bank credentials; None until set so the
    # app still boots with no .env. Never logged. See core/crypto.py and ADR 0003.
    encryption_key: str | None = Field(default=None, repr=False)
    # Enable Banking credentials. The application id is the JWT kid (not secret);
    # the private key is a secret file held outside the DB — only its path lives
    # here, never logged. Both None until configured. See docs/openbanking.md.
    enable_banking_application_id: str | None = None
    enable_banking_private_key_path: str | None = None
    # PEM content directly, for deployments with no writable filesystem to hold
    # a key file. Takes precedence over the path above when both are set.
    enable_banking_private_key_pem: str | None = None
    enable_banking_base_url: str = "https://api.enablebanking.com"
    # Must match the redirect registered in the Control Panel and the callback
    # endpoint. https is mandatory; localhost is accepted (docs/openbanking.md).
    enable_banking_redirect_url: str = "https://localhost:8000/connections/callback"
    # Country assumed when a request or stored connection carries none. Single
    # user, Italy-only for now — the client sends "IT" and POST /connections
    # defaults to it; named here so the logo backfill has one source for it.
    default_institution_country: str = "IT"
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
    # Funded-payment suggestions (a card charge funding a wallet payment) match
    # on an exact amount — no fee or FX drift between the legs — so this is 0 by
    # default. The day window above is reused. See services/transfers.py.
    funding_amount_tolerance_cents: int = 0
    # How many days before expiry a consent is surfaced as "expiring soon".
    # See domain/consent.py and docs/openbanking.md's expiry-warning constraint.
    consent_warning_window_days: int = 14
    # Largest import file accepted by POST /imports/* (ADR 0023), in bytes. A
    # personal monthly export is a few KB; 2 MiB is comfortable headroom and
    # still bounds the base64 body. Over this is a 413.
    import_max_bytes: int = 2 * 1024 * 1024
    # How many days a pending transaction may go unseen by a sync before it is
    # considered abandoned. See db/repositories.py::prune_stale_pending_transactions.
    pending_transaction_ttl_days: int = 30
    # Background sync scheduler (ADR 0010). Off by default — see the class
    # docstring; turning it on is a deliberate step, never a side effect of
    # booting with no .env.
    background_sync_enabled: bool = False
    background_sync_interval_minutes: int = 60
    background_sync_budget_per_day: int = 4
    sync_min_interval_hours: int = 6
    # PSU-present headers (ADR 0011). Built and tested, off by default: the
    # header set this codebase can honestly send is incomplete — see the
    # class docstring.
    send_psu_headers: bool = False
    # Shared bearer secret (ADR 0014). None by default — auth stays off until
    # a deployment deliberately sets it. repr=False like every other secret
    # so a whole-Settings log/repr can't leak it.
    api_token: str | None = Field(default=None, repr=False)
    # Dashboard FX conversion (ADR 0021). Off by default — the app must boot
    # with no .env without ever calling an external rate API; turning it on is
    # a deliberate step, same as background_sync_enabled. No secret: frankfurter
    # needs no key.
    fx_enabled: bool = False
    fx_base_currency: str = "EUR"
    fx_api_base_url: str = "https://api.frankfurter.dev/v1"
    # Only the most recent ECB date's row is ever re-fetched; historical rows
    # are immutable once stored.
    fx_rate_ttl_hours: int = 12

    @field_validator(
        "encryption_key",
        "enable_banking_application_id",
        "enable_banking_private_key_path",
        "enable_banking_private_key_pem",
        "api_token",
        mode="before",
    )
    @classmethod
    def _blank_env_means_unset(cls, value: str | None) -> str | None:
        """Treat a blank ``.env`` value the same as an absent one.

        ``.env.example`` leaves every optional secret blank (e.g.
        ``TRACCIO_API_TOKEN=``) rather than omitting the line, so
        pydantic-settings reads it as ``""``, not ``None`` — every caller's
        ``is None`` check (``api/deps.py::require_api_token``, this module's
        own production boot gate) would otherwise see a falsy-but-truthy
        sentinel and treat the secret as configured, e.g. requiring a bearer
        token no one set. Empty string and unset both mean "not configured".
        """
        return value or None


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
