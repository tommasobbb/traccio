"""Structured logging setup with structlog.

Configured here and invoked once at startup. Takes plain arguments rather than
importing :mod:`traccio.core.config`, so ``core/`` stays free of internal
coupling.

Remember ``.claude/rules/data-safety.md``: log identifiers and counts, never
whole objects and never financial data.
"""

import logging

import structlog

# Re-exported so callers get a logger with ``get_logger(__name__)`` without
# importing structlog directly.
get_logger = structlog.get_logger


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

    structlog.configure(
        processors=[*shared_processors, renderer],
        # Drop records below ``level`` as early as possible.
        wrapper_class=structlog.make_filtering_bound_logger(level),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
