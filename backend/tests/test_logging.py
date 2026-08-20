"""Tests for logging configuration, focused on the data-safety guarantee.

The HTTP client loggers (``httpx``/``httpcore``) emit one INFO record per
request whose message embeds the full request URL. For Enable Banking those
URLs carry the consent secret and account uids, so ``configure_logging`` must
pin those loggers above INFO regardless of the app's configured level (see
``.claude/rules/data-safety.md``). These tests use only synthetic values.
"""

import io
import logging

import pytest

from traccio.core.logging import _SILENCED_HTTP_LOGGERS, configure_logging


@pytest.mark.parametrize("name", _SILENCED_HTTP_LOGGERS)
def test_http_loggers_pinned_at_warning_by_default(name: str) -> None:
    """Each silenced HTTP logger sits at WARNING after default configuration."""
    configure_logging()

    assert logging.getLogger(name).level == logging.WARNING


@pytest.mark.parametrize("name", _SILENCED_HTTP_LOGGERS)
def test_http_loggers_stay_pinned_even_at_debug(name: str) -> None:
    """A DEBUG app level does not relax the HTTP loggers below WARNING.

    The named logger's own level filters before propagation to the root, so the
    per-request URL lines are dropped even when the app is at DEBUG.
    """
    configure_logging(log_level="DEBUG")

    assert logging.getLogger(name).level == logging.WARNING


def test_http_request_url_line_never_reaches_the_sink() -> None:
    """An INFO ``HTTP Request`` line is suppressed while a WARNING still passes.

    This is the behavioural guarantee: the URL-bearing INFO record (here with a
    synthetic ``SECRET`` in place of a real session id) is filtered out, but a
    genuine problem logged at WARNING is not.
    """
    configure_logging()
    httpx_logger = logging.getLogger("httpx")

    # Capture whatever the httpx logger emits, independent of the root handler.
    buffer = io.StringIO()
    handler = logging.StreamHandler(buffer)
    handler.setLevel(logging.DEBUG)
    httpx_logger.addHandler(handler)
    try:
        # The exact shape httpx would log for a data call — synthetic secret.
        httpx_logger.info('HTTP Request: GET /sessions/SECRET "HTTP/1.1 200 OK"')
        assert buffer.getvalue() == ""

        httpx_logger.warning("connection pool exhausted")
        assert "connection pool exhausted" in buffer.getvalue()
        assert "SECRET" not in buffer.getvalue()
    finally:
        httpx_logger.removeHandler(handler)
