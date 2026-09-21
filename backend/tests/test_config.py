"""Tests for ``core/config.py``'s blank-env-means-unset coercion.

``.env.example`` leaves every optional secret blank (``TRACCIO_API_TOKEN=``)
rather than omitting the line — a fresh clone following the README literally
produces a real environment variable set to ``""``, not an absent one. These
tests go through that same path (``monkeypatch.setenv`` + a bare
``Settings()``) rather than passing the field as a constructor kwarg, since
the bug this guards against only appears when pydantic-settings itself does
the parsing.
"""

import pytest

from traccio.core.config import Settings

_OPTIONAL_STR_FIELDS = [
    "encryption_key",
    "enable_banking_application_id",
    "enable_banking_private_key_path",
    "enable_banking_private_key_pem",
    "api_token",
]


@pytest.mark.parametrize("field", _OPTIONAL_STR_FIELDS)
def test_blank_env_value_is_read_as_unset(monkeypatch: pytest.MonkeyPatch, field: str) -> None:
    monkeypatch.setenv(f"TRACCIO_{field.upper()}", "")

    settings = Settings(_env_file=None)

    assert getattr(settings, field) is None


@pytest.mark.parametrize("field", _OPTIONAL_STR_FIELDS)
def test_real_env_value_still_comes_through(monkeypatch: pytest.MonkeyPatch, field: str) -> None:
    monkeypatch.setenv(f"TRACCIO_{field.upper()}", "a-real-value")

    settings = Settings(_env_file=None)

    assert getattr(settings, field) == "a-real-value"
