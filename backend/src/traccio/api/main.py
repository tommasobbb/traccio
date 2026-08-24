"""FastAPI application factory.

``api/`` sits on top of the other layers and may import from them (see
``docs/architecture.md``). This module is only the composition root: it wires
configuration and logging from ``core/`` and includes the per-resource routers.
Routes live in ``api/routers/`` and their schemas in ``api/schemas/``.
"""

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from traccio.api.deps import build_bank_provider
from traccio.api.routers import (
    accounts_router,
    advances_router,
    categories_router,
    connections_router,
    dashboard_router,
    events_router,
    health_router,
    rules_router,
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
    app = FastAPI(title="Traccio", version=app_version, lifespan=_lifespan)

    # Log identifiers only, never financial data (see data-safety rules).
    logger.info("app.startup", environment=settings.environment, version=app_version)

    app.include_router(health_router)
    app.include_router(accounts_router)
    app.include_router(connections_router)
    app.include_router(transactions_router)
    app.include_router(transfers_router)
    app.include_router(advances_router)
    app.include_router(events_router)
    app.include_router(categories_router)
    app.include_router(rules_router)
    app.include_router(dashboard_router)

    return app


# Module-level instance imported by uvicorn (``traccio.api.main:app``).
app = create_app()
