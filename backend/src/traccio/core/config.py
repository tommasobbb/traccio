"""Application configuration, loaded from the environment.

`core/` imports nothing from the rest of the project (see
`docs/architecture.md`); this module depends only on the standard library and
pydantic-settings.
"""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Settings read from environment variables (prefix ``TRACCIO_``).

    Defaults are chosen so the app boots with no ``.env`` present. A
    committable ``.env.example`` documents the available variables.
    """

    model_config = SettingsConfigDict(
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


@lru_cache
def get_settings() -> Settings:
    """Return the process-wide settings, loaded once."""
    return Settings()
