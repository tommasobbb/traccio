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
