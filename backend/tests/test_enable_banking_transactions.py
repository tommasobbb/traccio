"""Tests for the pure Enable Banking transaction normalizers.

No network and no database: these exercise the field-by-field mapping directly.
Every value is synthetic — invented amounts, ``"TEST MERCHANT 01"`` descriptions
(see ``.claude/rules/data-safety.md``).
"""

from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

import pytest

from traccio.domain import Account, AccountKind
from traccio.domain.enums import KeyStrategy, TransactionStatus
from traccio.providers.base import ProviderError
from traccio.providers.enable_banking.transactions import to_transaction


def _account(kind: AccountKind = AccountKind.CURRENT) -> Account:
    return Account(
        user_id=uuid4(),
        connection_id=uuid4(),
        kind=kind,
        currency="EUR",
        identification_hash="IDHASH-01",
    )


def _entry(**overrides: Any) -> dict[str, Any]:
    """A well-formed booked debit entry, overridable per test."""
    entry: dict[str, Any] = {
        "entry_reference": "ENTRY-01",
        "transaction_amount": {"currency": "EUR", "amount": "12.34"},
        "credit_debit_indicator": "DBIT",
        "status": "BOOK",
        "booking_date": "2026-08-15",
        "value_date": "2026-08-16",
        "remittance_information": ["TEST MERCHANT 01"],
    }
    entry.update(overrides)
    return entry


def test_debit_entry_is_negative_and_uses_entry_reference() -> None:
    account = _account()
    tx = to_transaction(_entry(), account=account)

    assert tx.money.amount == -1234  # DBIT -> money left the account
    assert tx.money.currency == "EUR"
    assert tx.account_id == account.id
    assert tx.user_id == account.user_id
    assert tx.status is TransactionStatus.BOOKED
    assert tx.description == "TEST MERCHANT 01"
    assert tx.booked_at == datetime(2026, 8, 15, tzinfo=UTC)
    assert tx.value_date == datetime(2026, 8, 16, tzinfo=UTC)
    assert tx.entry_reference == "ENTRY-01"
    assert tx.stable_key == "ENTRY-01"
    assert tx.key_strategy is KeyStrategy.ENTRY_REFERENCE


def test_credit_entry_is_positive() -> None:
    tx = to_transaction(_entry(credit_debit_indicator="CRDT"), account=_account())
    assert tx.money.amount == 1234


def test_transaction_currency_can_differ_from_account_currency() -> None:
    # A card purchase abroad settles in another currency than the account.
    entry = _entry(transaction_amount={"currency": "GBP", "amount": "10.00"})
    tx = to_transaction(entry, account=_account(kind=AccountKind.CARD))
    assert tx.money.currency == "GBP"


def test_missing_entry_reference_derives_a_deterministic_hash() -> None:
    account = _account()
    entry = _entry(entry_reference=None)

    first = to_transaction(entry, account=account)
    second = to_transaction(entry, account=account)

    assert first.entry_reference is None
    assert first.key_strategy is KeyStrategy.DERIVED_HASH
    assert len(first.stable_key) == 64  # sha256 hexdigest, fits the 128-char column
    # Deterministic across runs for identical inputs.
    assert first.stable_key == second.stable_key


def test_derived_hash_differs_when_amount_differs() -> None:
    account = _account()
    a = to_transaction(
        _entry(entry_reference=None, transaction_amount={"currency": "EUR", "amount": "12.34"}),
        account=account,
    )
    b = to_transaction(
        _entry(entry_reference=None, transaction_amount={"currency": "EUR", "amount": "56.78"}),
        account=account,
    )
    assert a.stable_key != b.stable_key


def test_pending_entry_without_booking_date_has_no_booked_at() -> None:
    entry = _entry(status="PDNG", booking_date=None)
    tx = to_transaction(entry, account=_account())
    assert tx.status is TransactionStatus.PENDING
    assert tx.booked_at is None


def test_empty_remittance_information_yields_empty_description() -> None:
    tx = to_transaction(_entry(remittance_information=None), account=_account())
    assert tx.description == ""


def test_amount_with_sub_cent_precision_is_rejected() -> None:
    entry = _entry(transaction_amount={"currency": "EUR", "amount": "12.345"})
    with pytest.raises(ProviderError):
        to_transaction(entry, account=_account())


def test_non_numeric_amount_is_rejected_without_leaking_the_value() -> None:
    entry = _entry(transaction_amount={"currency": "EUR", "amount": "not-a-number"})
    with pytest.raises(ProviderError) as excinfo:
        to_transaction(entry, account=_account())
    assert "not-a-number" not in str(excinfo.value)


def test_unknown_indicator_is_rejected() -> None:
    with pytest.raises(ProviderError):
        to_transaction(_entry(credit_debit_indicator="XXXX"), account=_account())


def test_rejected_status_maps_to_rejected() -> None:
    # RJCT (refused/reversed, terminal like booked) — first seen in the PayPal ledger.
    tx = to_transaction(_entry(status="RJCT"), account=_account())
    assert tx.status is TransactionStatus.REJECTED


def test_unknown_status_is_rejected() -> None:
    # INFO and other codes are refused rather than coerced (fail loud on first sync).
    with pytest.raises(ProviderError):
        to_transaction(_entry(status="INFO"), account=_account())


def test_missing_amount_block_is_rejected() -> None:
    entry = _entry()
    del entry["transaction_amount"]
    with pytest.raises(ProviderError):
        to_transaction(entry, account=_account())


def test_malformed_date_is_rejected() -> None:
    with pytest.raises(ProviderError):
        to_transaction(_entry(booking_date="not-a-date"), account=_account())
