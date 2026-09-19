"""FastAPI application factory.

``api/`` sits on top of the other layers and may import from them (see
``docs/architecture.md``). This module is only the composition root: it wires
configuration and logging from ``core/`` and includes the per-resource routers.
Routes live in ``api/routers/`` and their schemas in ``api/schemas/``.
"""

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import APIRouter, Depends, FastAPI

from traccio.api.deps import build_bank_provider, require_api_token
from traccio.api.routers import (
    accounts_router,
    advances_router,
    categories_router,
    connections_callback_router,
    connections_router,
    dashboard_router,
    events_router,
    health_router,
    imports_router,
    reimbursements_router,
    rules_router,
    settings_router,
    transactions_router,
    transfers_router,
)
from traccio.api.version import resolve_version
from traccio.core.config import get_settings
from traccio.core.crypto import get_token_cipher
from traccio.core.logging import configure_logging, get_logger
from traccio.services.scheduler import run_scheduler

logger = get_logger(__name__)


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Start and stop the background sync scheduler around the app's life.

    A no-op unless ``TRACCIO_BACKGROUND_SYNC_ENABLED`` is set (ADR 0010): the
    app must boot with no ``.env`` present, and turning on a loop that calls
    a real bank is a deliberate step, not a side effect of starting the
    server. When enabled, builds one provider and cipher for the scheduler's
    whole run (not one per tick) and closes the provider's client on
    shutdown; ``stop_event`` lets the loop end its current wait cleanly
    rather than being cancelled mid-tick.
    """
    settings = get_settings()
    if not settings.background_sync_enabled:
        yield
        return

    provider, client = build_bank_provider()
    cipher = get_token_cipher(settings.encryption_key)
    stop_event = asyncio.Event()
    task = asyncio.create_task(
        run_scheduler(
            provider=provider,
            cipher=cipher,
            user_id=settings.dev_user_id,
            interval_minutes=settings.background_sync_interval_minutes,
            initial_history_days=settings.initial_history_days,
            sync_overlap_days=settings.sync_overlap_days,
            consent_warning_window_days=settings.consent_warning_window_days,
            budget_per_day=settings.background_sync_budget_per_day,
            min_interval_hours=settings.sync_min_interval_hours,
            stop_event=stop_event,
        )
    )
    logger.info("scheduler.started", interval_minutes=settings.background_sync_interval_minutes)
    try:
        yield
    finally:
        stop_event.set()
        await task
        client.close()
        logger.info("scheduler.stopped")


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

    # Fail loudly and early (docs/engineering.md): an unauthenticated
    # API is the deliberate localhost default (ADR 0014), but "production"
    # declared with no token would otherwise boot exposing every user's
    # financial data behind nothing but a log line. Development and test
    # environments are unaffected — only a literal "production" is gated.
    if settings.environment == "production" and settings.api_token is None:
        raise RuntimeError("TRACCIO_API_TOKEN is required when TRACCIO_ENVIRONMENT=production")

    app = FastAPI(title="Traccio", version=app_version, lifespan=_lifespan)

    # Log identifiers only, never financial data (see data-safety rules).
    logger.info("app.startup", environment=settings.environment, version=app_version)
    if settings.api_token is None:
        logger.warning("auth.disabled")

    # Every resource router except health and the consent callback requires
    # Settings.api_token (ADR 0014) — gated once here on a parent router
    # rather than on each include_router call. health has no data to protect;
    # the callback is reached by the bank's browser redirect, which cannot
    # carry a bearer header, and is protected by its own state value instead
    # (api/routers/connections.py).
    protected = APIRouter()
    protected.include_router(accounts_router)
    protected.include_router(connections_router)
    protected.include_router(transactions_router)
    protected.include_router(transfers_router)
    protected.include_router(imports_router)
    protected.include_router(advances_router)
    protected.include_router(reimbursements_router)
    protected.include_router(events_router)
    protected.include_router(categories_router)
    protected.include_router(rules_router)
    protected.include_router(dashboard_router)
    protected.include_router(settings_router)

    app.include_router(health_router)
    app.include_router(connections_callback_router)
    app.include_router(protected, dependencies=[Depends(require_api_token)])

    return app


# Module-level instance imported by uvicorn (``traccio.api.main:app``).
app = create_app()
