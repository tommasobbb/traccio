"""Tests for the ``create_app`` composition root (``api/main.py``).

Monkeypatches ``traccio.api.main.get_settings`` directly rather than going
through ``app.dependency_overrides`` (as ``tests/test_auth.py`` does for
request-scoped checks): the boot-time gate below runs inside ``create_app()``
itself, before any dependency injection exists to override.
"""

import pytest

import traccio.api.main as main_module
from traccio.core.config import Settings


def test_production_with_no_api_token_refuses_to_boot(monkeypatch: pytest.MonkeyPatch) -> None:
    """A ``production`` deployment with no bearer token must not boot open.

    ADR 0014's unauthenticated-on-localhost default is deliberate for
    development, but "production" declared alongside a blank
    ``TRACCIO_API_TOKEN`` is a misconfiguration, not a valid deployment —
    it would otherwise serve every endpoint's financial data behind nothing
    but a log warning.
    """
    monkeypatch.setattr(
        main_module,
        "get_settings",
        lambda: Settings(environment="production", api_token=None),
    )

    with pytest.raises(RuntimeError, match="TRACCIO_API_TOKEN"):
        main_module.create_app()


def test_production_with_an_api_token_boots_normally(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        main_module,
        "get_settings",
        lambda: Settings(environment="production", api_token="TEST-TOKEN-01"),
    )

    app = main_module.create_app()

    assert app is not None


def test_development_with_no_api_token_boots_normally(monkeypatch: pytest.MonkeyPatch) -> None:
    """The default every other test in this suite relies on."""
    monkeypatch.setattr(
        main_module,
        "get_settings",
        lambda: Settings(environment="development", api_token=None),
    )

    app = main_module.create_app()

    assert app is not None
