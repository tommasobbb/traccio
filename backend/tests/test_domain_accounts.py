"""Tests for the pure account rules (``domain/accounts``).

Pure unit tests: no database, no network. Fixtures use synthetic values only
(invented account names) — see ``.claude/rules/data-safety.md``.
"""

from uuid import uuid4

import pytest

from traccio.domain import Account, AccountKind
from traccio.domain.accounts import (
    MAX_ACCOUNT_ALIAS_LENGTH,
    REASON_ALIAS_TOO_LONG,
    REASON_BLANK_ALIAS,
    AccountError,
    account_source,
    display_name,
    normalize_account_alias,
)
from traccio.domain.enums import AccountSource


def _account(*, name: str | None = None, alias: str | None = None) -> Account:
    """Build a synthetic account with optional ``name``/``alias``."""
    return Account(
        user_id=uuid4(),
        connection_id=uuid4(),
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash="TEST-HASH-01",
        name=name,
        alias=alias,
    )


def test_normalize_account_alias_strips_whitespace() -> None:
    assert normalize_account_alias("  My salary account  ") == "My salary account"


def test_normalize_account_alias_passes_through_none() -> None:
    """``None`` is a valid input — it means "clear the alias"."""
    assert normalize_account_alias(None) is None


def test_normalize_account_alias_rejects_blank_after_stripping() -> None:
    with pytest.raises(AccountError) as exc_info:
        normalize_account_alias("   ")
    assert exc_info.value.reason == REASON_BLANK_ALIAS


def test_normalize_account_alias_rejects_too_long() -> None:
    too_long = "a" * (MAX_ACCOUNT_ALIAS_LENGTH + 1)
    with pytest.raises(AccountError) as exc_info:
        normalize_account_alias(too_long)
    assert exc_info.value.reason == REASON_ALIAS_TOO_LONG


def test_normalize_account_alias_accepts_max_length() -> None:
    max_length = "a" * MAX_ACCOUNT_ALIAS_LENGTH
    assert normalize_account_alias(max_length) == max_length


def test_display_name_prefers_alias_over_provider_name() -> None:
    account = _account(name="TEST CURRENT 01", alias="My salary account")
    assert display_name(account) == "My salary account"


def test_display_name_falls_back_to_provider_name_when_alias_unset() -> None:
    account = _account(name="TEST CURRENT 01", alias=None)
    assert display_name(account) == "TEST CURRENT 01"


def test_display_name_is_none_when_neither_is_set() -> None:
    account = _account(name=None, alias=None)
    assert display_name(account) is None


def test_account_source_is_synced_when_connected() -> None:
    assert account_source(_account(name="TEST CURRENT 01")) is AccountSource.SYNCED


def test_account_source_is_manual_when_no_connection() -> None:
    manual = Account(user_id=uuid4(), kind=AccountKind.CASH, currency="EUR", alias="Contanti")
    assert account_source(manual) is AccountSource.MANUAL


def test_account_rejects_connection_without_identity() -> None:
    with pytest.raises(ValueError, match="both set"):
        Account(
            user_id=uuid4(),
            connection_id=uuid4(),
            kind=AccountKind.CURRENT,
            currency="EUR",
            identification_hash=None,
        )


def test_account_rejects_identity_without_connection() -> None:
    with pytest.raises(ValueError, match="both set"):
        Account(
            user_id=uuid4(),
            connection_id=None,
            kind=AccountKind.CURRENT,
            currency="EUR",
            identification_hash="TEST-HASH-01",
        )
