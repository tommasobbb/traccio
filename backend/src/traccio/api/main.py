"""FastAPI application entry point.

`api/` sits on top of the other layers and may import from them (see
`docs/architecture.md`). Here it wires configuration and logging from `core/`
and exposes the health endpoint.
"""

from importlib.metadata import PackageNotFoundError, version

from fastapi import FastAPI
from pydantic import BaseModel

from traccio.core.config import get_settings
from traccio.core.logging import configure_logging, get_logger

logger = get_logger(__name__)


def _app_version() -> str:
    """Resolve the installed package version, without hardcoding it."""
    try:
        return version("traccio")
    except PackageNotFoundError:
        return "0.0.0"


class HealthResponse(BaseModel):
    """Payload returned by the health endpoint."""

    status: str
    version: str


def create_app() -> FastAPI:
    """Build and configure the FastAPI application."""
    settings = get_settings()
    configure_logging(log_level=settings.log_level, json_logs=settings.log_json)

    app_version = _app_version()
    app = FastAPI(title="Traccio", version=app_version)

    # Log identifiers only, never financial data (see data-safety rules).
    logger.info("app.startup", environment=settings.environment, version=app_version)

    @app.get("/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse(status="ok", version=app_version)

    return app


app = create_app()
