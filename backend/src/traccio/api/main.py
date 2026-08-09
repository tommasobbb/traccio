"""FastAPI application entry point.

``api/`` sits on top of the other layers and may import from them (see
``docs/architecture.md``). Here it wires configuration and logging from
``core/`` and exposes the health endpoint.
"""

from datetime import datetime
from importlib.metadata import PackageNotFoundError, version
from typing import Annotated
from uuid import UUID

from fastapi import Depends, FastAPI
from pydantic import BaseModel
from sqlalchemy.orm import Session

from traccio.core.config import get_settings
from traccio.core.logging import configure_logging, get_logger
from traccio.db.repositories import list_accounts
from traccio.db.session import get_session
from traccio.domain.enums import AccountKind

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


class AccountResponse(BaseModel):
    """One account as returned to the client.

    A deliberately narrow projection of :class:`~traccio.domain.models.Account`:
    ``user_id`` (implied by the caller) and ``identification_hash`` (an internal
    matching detail) are intentionally omitted.

    Attributes
    ----------
    id : UUID
        Stable account identifier.
    connection_id : UUID
        Connection currently exposing this account.
    kind : AccountKind
        ``current``, ``savings``, or ``card``.
    currency : str
        The account's ISO 4217 currency.
    name : str or None
        Optional display name.
    created_at : datetime
        When the account was first recorded.
    """

    id: UUID
    connection_id: UUID
    kind: AccountKind
    currency: str
    name: str | None
    created_at: datetime


class AccountsResponse(BaseModel):
    """Envelope for the account list.

    A wrapper object rather than a bare array leaves room for pagination or
    metadata later without breaking the generated Swift client.

    Attributes
    ----------
    accounts : list[AccountResponse]
        The caller's accounts, oldest first.
    """

    accounts: list[AccountResponse]


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

    @app.get("/accounts", response_model=AccountsResponse)
    def accounts(
        session: Annotated[Session, Depends(get_session)],
    ) -> AccountsResponse:
        """List the current user's accounts.

        Scoped to ``settings.dev_user_id`` — the single-user stand-in until real
        auth (see :class:`~traccio.core.config.Settings`). The query itself is
        already written ``scoped by user_id``; only the source of the id changes
        when auth arrives.

        Parameters
        ----------
        session : Session
            Request-scoped database session (see :func:`get_session`).

        Returns
        -------
        AccountsResponse
            The user's accounts, oldest first.
        """
        found = list_accounts(session, settings.dev_user_id)
        # Log a count, never account contents (see data-safety rules).
        logger.info("accounts.list", count=len(found))
        return AccountsResponse(
            accounts=[
                AccountResponse(
                    id=account.id,
                    connection_id=account.connection_id,
                    kind=account.kind,
                    currency=account.currency,
                    name=account.name,
                    created_at=account.created_at,
                )
                for account in found
            ]
        )

    return app


# Module-level instance imported by uvicorn (``traccio.api.main:app``).
app = create_app()
