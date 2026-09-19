"""Structured logging setup with structlog.

Configured here and invoked once at startup. Takes plain arguments rather than
importing :mod:`traccio.core.config`, so ``core/`` stays free of internal
coupling.

Remember ``docs/engineering.md``: log identifiers and counts, never
whole objects and never financial data.
"""

import logging

import structlog

# Re-exported so callers get a logger with ``get_logger(__name__)`` without
# importing structlog directly.
get_logger = structlog.get_logger

# Third-party HTTP client loggers whose INFO/DEBUG records include full request
# URLs. For Enable Banking those URLs carry the consent secret
# (``/sessions/{session_id}``) and account uids (``/accounts/{account_uid}/...``),
# so they must never reach the log sink (see ``docs/engineering.md``).
# Pinned at WARNING regardless of the app's configured level.
_SILENCED_HTTP_LOGGERS = ("httpx", "httpcore")


def configure_logging(*, log_level: str = "INFO", json_logs: bool = False) -> None:
    """Configure structlog and the stdlib logging backend.

    Idempotent enough to call once at application startup (see
    :func:`traccio.api.main.create_app`). Arguments are plain values rather than
    a settings object on purpose, to keep this module decoupled from
    :mod:`traccio.core.config`.

    Parameters
    ----------
    log_level : str, optional
        Minimum level name, e.g. ``"INFO"`` or ``"DEBUG"``. Unknown names fall
        back to ``INFO``. Defaults to ``"INFO"``.
    json_logs : bool, optional
        Emit JSON lines when ``True`` (production), otherwise a human-readable
        console renderer (development). Defaults to ``False``.

    Returns
    -------
    None

    Notes
    -----
    The HTTP client loggers in :data:`_SILENCED_HTTP_LOGGERS` are pinned at
    ``WARNING`` so their per-request URL lines (which embed consent secrets and
    account uids) never reach the sink, even when the app runs at ``DEBUG``.
    """
    # Map the level name to its numeric value, defaulting to INFO if unknown.
    level = logging.getLevelNamesMapping().get(log_level.upper(), logging.INFO)

    # Processors shared by both renderers: context merging, level and timestamp
    # enrichment, and exception/stack formatting. The renderer is appended last.
    shared_processors: list[structlog.typing.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
    ]

    # JSON for machines in production, coloured console output for humans in dev.
    renderer: structlog.typing.Processor = (
        structlog.processors.JSONRenderer() if json_logs else structlog.dev.ConsoleRenderer()
    )

    # Route stdlib logging through the same level so third-party libraries that
    # use ``logging`` honour the configured threshold.
    logging.basicConfig(format="%(message)s", level=level)

    # Pin the HTTP client loggers above INFO so their per-request URL lines
    # (consent secrets, account uids) never reach the sink. A named logger's own
    # level filters before propagation, so this holds even at DEBUG.
    for name in _SILENCED_HTTP_LOGGERS:
        logging.getLogger(name).setLevel(logging.WARNING)

    structlog.configure(
        processors=[*shared_processors, renderer],
        # Drop records below ``level`` as early as possible.
        wrapper_class=structlog.make_filtering_bound_logger(level),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
