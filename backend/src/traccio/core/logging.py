"""Structured logging setup with structlog.

Configured here and invoked once at startup. Takes plain arguments rather than
importing :mod:`traccio.core.config`, so `core/` stays free of internal
coupling.

Remember `.claude/rules/data-safety.md`: log identifiers and counts, never
whole objects and never financial data.
"""

import logging

import structlog

get_logger = structlog.get_logger


def configure_logging(*, log_level: str = "INFO", json_logs: bool = False) -> None:
    """Configure structlog and the stdlib logging backend.

    Args:
        log_level: Minimum level name (e.g. ``"INFO"``, ``"DEBUG"``).
        json_logs: Emit JSON lines when ``True`` (production), otherwise a
            human-readable console renderer (development).
    """
    level = logging.getLevelNamesMapping().get(log_level.upper(), logging.INFO)

    shared_processors: list[structlog.typing.Processor] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
    ]

    renderer: structlog.typing.Processor = (
        structlog.processors.JSONRenderer() if json_logs else structlog.dev.ConsoleRenderer()
    )

    logging.basicConfig(format="%(message)s", level=level)

    structlog.configure(
        processors=[*shared_processors, renderer],
        wrapper_class=structlog.make_filtering_bound_logger(level),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
