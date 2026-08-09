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
