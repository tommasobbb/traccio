"""Tests for the pure Enable Banking transaction normalizers.

No network and no database: these exercise the field-by-field mapping directly.
Every value is synthetic — invented amounts, ``"TEST MERCHANT 01"`` descriptions
(see ``.claude/rules/data-safety.md``).
"""

import hashlib
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


# -- value_date fallback chain (found 2026-08-27 debugging PayPal) ----------


def test_value_date_falls_back_to_transaction_date_when_value_date_missing() -> None:
    entry = _entry(value_date=None, transaction_date="2026-08-17")
    tx = to_transaction(entry, account=_account())
    assert tx.value_date == datetime(2026, 8, 17, tzinfo=UTC)


def test_value_date_wins_over_transaction_date_when_both_present() -> None:
    # _entry()'s value_date is 2026-08-16; a transaction_date must not override it.
    tx = to_transaction(_entry(transaction_date="2099-01-01"), account=_account())
    assert tx.value_date == datetime(2026, 8, 16, tzinfo=UTC)


def test_value_date_is_none_when_no_date_source_is_present() -> None:
    tx = to_transaction(_entry(value_date=None), account=_account())
    assert tx.value_date is None


def test_booked_at_has_no_fallback_even_when_transaction_date_present() -> None:
    # booked_at stays the modelled "not yet settled" signal — pins the B1
    # decision that only value_date gets a fallback, never booked_at.
    entry = _entry(booking_date=None, value_date=None, transaction_date="2026-08-17")
    tx = to_transaction(entry, account=_account())
    assert tx.booked_at is None
    assert tx.value_date == datetime(2026, 8, 17, tzinfo=UTC)


def test_malformed_transaction_date_is_rejected() -> None:
    entry = _entry(value_date=None, transaction_date="not-a-date")
    with pytest.raises(ProviderError):
        to_transaction(entry, account=_account())


# -- description fallback chain (found 2026-08-27 debugging PayPal) --------


def test_remittance_information_as_plain_string_is_accepted() -> None:
    tx = to_transaction(_entry(remittance_information="TEST MERCHANT 02"), account=_account())
    assert tx.description == "TEST MERCHANT 02"


def test_debit_description_falls_back_to_creditor_name() -> None:
    entry = _entry(
        credit_debit_indicator="DBIT",
        remittance_information=None,
        creditor={"name": "TEST CREDITOR 01"},
    )
    tx = to_transaction(entry, account=_account())
    assert tx.description == "TEST CREDITOR 01"


def test_credit_description_falls_back_to_debtor_name() -> None:
    entry = _entry(
        credit_debit_indicator="CRDT",
        remittance_information=None,
        debtor={"name": "TEST DEBTOR 01"},
    )
    tx = to_transaction(entry, account=_account())
    assert tx.description == "TEST DEBTOR 01"


def test_wrong_direction_counterparty_is_not_used() -> None:
    # A debit only looks at creditor; a debtor present alongside it is ignored.
    entry = _entry(
        credit_debit_indicator="DBIT",
        remittance_information=None,
        debtor={"name": "TEST DEBTOR 01"},
    )
    tx = to_transaction(entry, account=_account())
    assert tx.description == ""


def test_empty_remittance_list_falls_back_to_counterparty_name() -> None:
    entry = _entry(remittance_information=[], creditor={"name": "TEST CREDITOR 01"})
    tx = to_transaction(entry, account=_account())
    assert tx.description == "TEST CREDITOR 01"


def test_remittance_wins_over_counterparty_name() -> None:
    entry = _entry(
        remittance_information=["TEST MERCHANT 01"],
        creditor={"name": "TEST CREDITOR 01"},
    )
    tx = to_transaction(entry, account=_account())
    assert tx.description == "TEST MERCHANT 01"


def test_malformed_counterparty_yields_empty_description_without_raising() -> None:
    entry = _entry(remittance_information=None, creditor="not-a-dict")
    tx = to_transaction(entry, account=_account())
    assert tx.description == ""

    entry_bad_name = _entry(remittance_information=None, creditor={"name": 123})
    tx_bad_name = to_transaction(entry_bad_name, account=_account())
    assert tx_bad_name.description == ""


# -- the regression test that would have caught the PayPal bug -------------


def test_paypal_shaped_entry_gets_a_date_and_a_description() -> None:
    """No booking_date, no value_date, no remittance_information — PayPal's
    actual shape. Both fallback chains must fire together."""
    entry = _entry(
        booking_date=None,
        value_date=None,
        remittance_information=None,
        transaction_date="2026-08-20",
        creditor={"name": "TEST CREDITOR 01"},
    )
    tx = to_transaction(entry, account=_account())

    assert tx.value_date == datetime(2026, 8, 20, tzinfo=UTC)
    assert tx.description == "TEST CREDITOR 01"
    assert tx.booked_at is None
    assert tx.key_strategy is KeyStrategy.ENTRY_REFERENCE


# -- B4: the derived-hash key uses the resolved (post-fallback) values -----


def test_derived_hash_uses_resolved_value_date_and_description() -> None:
    account = _account()
    entry = _entry(
        entry_reference=None,
        booking_date=None,
        value_date=None,
        remittance_information=None,
        transaction_date="2026-08-20",
        creditor={"name": "TEST CREDITOR 01"},
    )
    tx = to_transaction(entry, account=account)
    assert tx.key_strategy is KeyStrategy.DERIVED_HASH

    resolved_components = [
        str(account.id),
        datetime(2026, 8, 20, tzinfo=UTC).isoformat(),
        str(tx.money.amount),
        "EUR",
        "TEST CREDITOR 01",
    ]
    expected_digest = hashlib.sha256("\x1f".join(resolved_components).encode("utf-8")).hexdigest()
    assert tx.stable_key == expected_digest

    # Pin against the alternative: hashing the raw pre-fallback values (no
    # value_date, no description) would give a different, wrong key.
    raw_components = [str(account.id), "", str(tx.money.amount), "EUR", ""]
    raw_digest = hashlib.sha256("\x1f".join(raw_components).encode("utf-8")).hexdigest()
    assert tx.stable_key != raw_digest
