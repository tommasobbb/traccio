"""FastAPI application entry point.

``api/`` sits on top of the other layers and may import from them (see
``docs/architecture.md``). Here it wires configuration and logging from
``core/`` and exposes the health endpoint.
"""

from importlib.metadata import PackageNotFoundError, version

from fastapi import FastAPI
from pydantic import BaseModel

from traccio.core.config import get_settings
from traccio.core.logging import configure_logging, get_logger

logger = get_logger(__name__)


def _app_version() -> str:
    """Resolve the installed package version.

    Reads the version from installed package metadata rather than hardcoding
    it, so the running app and the distribution never disagree.

    Returns
    -------
    str
        The installed ``traccio`` version, or ``"0.0.0"`` when the package is
        not installed (e.g. an editable tree without metadata).
    """
    try:
        return version("traccio")
    except PackageNotFoundError:
        return "0.0.0"


class HealthResponse(BaseModel):
    """Payload returned by the health endpoint.

    Attributes
    ----------
    status : str
        Liveness marker; ``"ok"`` when the app is serving.
    version : str
        The running application version (see :func:`_app_version`).
    """

    status: str
    version: str


def create_app() -> FastAPI:
    """Build and configure the FastAPI application.

    Acts as the composition root: it reads settings, configures logging, wires
    the routes, and returns the app. The module-level ``app`` below is the
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

    app_version = _app_version()
    app = FastAPI(title="Traccio", version=app_version)

    # Log identifiers only, never financial data (see data-safety rules).
    logger.info("app.startup", environment=settings.environment, version=app_version)

    @app.get("/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        """Report liveness and the running version.

        Returns
        -------
        HealthResponse
            ``status="ok"`` and the current application version.
        """
        return HealthResponse(status="ok", version=app_version)

    return app


# Module-level instance imported by uvicorn (``traccio.api.main:app``).
app = create_app()
