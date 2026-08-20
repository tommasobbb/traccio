"""FastAPI application factory.

``api/`` sits on top of the other layers and may import from them (see
``docs/architecture.md``). This module is only the composition root: it wires
configuration and logging from ``core/`` and includes the per-resource routers.
Routes live in ``api/routers/`` and their schemas in ``api/schemas/``.
"""

from fastapi import FastAPI

from traccio.api.routers import accounts_router, connections_router, health_router
from traccio.api.version import resolve_version
from traccio.core.config import get_settings
from traccio.core.logging import configure_logging, get_logger

logger = get_logger(__name__)


def create_app() -> FastAPI:
    """Build and configure the FastAPI application.

    Acts as the composition root: it reads settings, configures logging, wires
    the routers, and returns the app. The module-level ``app`` below is the
    instance uvicorn imports.

    Returns
    -------
    FastAPI
        The configured application, ready to serve.
    """
    settings = get_settings()
    # Configure logging before anything logs, passing plain values so core/
    # logging stays decoupled from the settings object.
    configure_logging(log_level=settings.log_level, json_logs=settings.log_json)

    app_version = resolve_version()
    app = FastAPI(title="Traccio", version=app_version)

    # Log identifiers only, never financial data (see data-safety rules).
    logger.info("app.startup", environment=settings.environment, version=app_version)

    app.include_router(health_router)
    app.include_router(accounts_router)
    app.include_router(connections_router)

    return app


# Module-level instance imported by uvicorn (``traccio.api.main:app``).
app = create_app()
