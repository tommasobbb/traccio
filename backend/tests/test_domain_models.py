"""Tests for the core domain entities and the Money value object.

Pure unit tests: no database, no network. Fixtures use synthetic values only
(round amounts, invented references, ``"TEST MERCHANT 01"``), never real bank
data — see ``.claude/rules/data-safety.md``.
"""

from uuid import uuid4

import pytest
from pydantic import ValidationError

from traccio.domain import (
    Account,
    AccountKind,
    Connection,
    ConnectionStatus,
    KeyStrategy,
    Money,
    SyncRun,
    SyncRunOutcome,
    SyncTrigger,
    Transaction,
    TransactionRole,
    TransactionStatus,
    User,
)


def test_money_accepts_integer_cents() -> None:
    """Money stores an integer minor-unit amount with an explicit currency."""
    money = Money(amount=-1234, currency="EUR")

    assert money.amount == -1234
    assert money.currency == "EUR"


def test_money_rejects_float_amount() -> None:
    """A float amount is rejected rather than silently truncated (StrictInt)."""
    with pytest.raises(ValidationError):
        Money(amount=12.34, currency="EUR")  # type: ignore[arg-type]


@pytest.mark.parametrize("bad_currency", ["eur", "EU", "EURO", "E1R", ""])
def test_money_rejects_malformed_currency(bad_currency: str) -> None:
    """Currency must be three uppercase letters (ISO 4217 shape)."""
    with pytest.raises(ValidationError):
        Money(amount=100, currency=bad_currency)


def test_money_is_frozen() -> None:
    """Money is immutable: reassigning a field raises."""
    money = Money(amount=100, currency="EUR")

    with pytest.raises(ValidationError):
        money.amount = 200  # type: ignore[misc]


def test_user_defaults() -> None:
    """A User gets an id and a timezone-aware created_at by default."""
    user = User()

    assert user.created_at.tzinfo is not None


def test_connection_expires_at_optional() -> None:
    """A pending connection may have no expiry yet."""
    connection = Connection(
        user_id=uuid4(),
        provider="enable_banking",
        institution_name="TEST BANK 01",
        status=ConnectionStatus.PENDING,
    )

    assert connection.expires_at is None
    assert connection.status is ConnectionStatus.PENDING


def test_account_construction() -> None:
    """An account carries its kind, currency, and derived stable identity."""
    account = Account(
        user_id=uuid4(),
        connection_id=uuid4(),
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash="hash-abc",
    )

    assert account.kind is AccountKind.CURRENT
    assert account.name is None


def test_transaction_role_defaults_to_personal() -> None:
    """Role defaults to personal; nothing infers a different role silently."""
    transaction = Transaction(
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-500, currency="EUR"),
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        stable_key="entryref-001",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )

    assert transaction.role is TransactionRole.PERSONAL
    assert transaction.money.amount == -500


def test_entities_forbid_unknown_fields() -> None:
    """extra='forbid' guards against typo'd or stale field names."""
    with pytest.raises(ValidationError):
        User(unexpected="x")  # type: ignore[call-arg]


def test_enum_values_are_stable() -> None:
    """Enum wire values stay stable across serialization and storage."""
    assert ConnectionStatus.ACTIVE.value == "active"
    assert AccountKind.CARD.value == "card"
    assert AccountKind.WALLET.value == "wallet"
    assert TransactionStatus.PENDING.value == "pending"
    assert TransactionStatus.REJECTED.value == "rejected"
    assert TransactionRole.REIMBURSEMENT.value == "reimbursement"
    assert KeyStrategy.DERIVED_HASH.value == "derived_hash"


def test_sync_run_defaults_and_fields() -> None:
    """A SyncRun records trigger, outcome, counts, and an optional reason."""
    sync_run = SyncRun(
        user_id=uuid4(),
        connection_id=uuid4(),
        trigger=SyncTrigger.BACKGROUND,
        outcome=SyncRunOutcome.SKIPPED_BUDGET,
        accounts_synced=0,
        transactions_synced=0,
    )

    assert sync_run.trigger is SyncTrigger.BACKGROUND
    assert sync_run.outcome is SyncRunOutcome.SKIPPED_BUDGET
    assert sync_run.error_reason is None
    assert sync_run.started_at.tzinfo is not None


def test_sync_run_forbids_unknown_fields() -> None:
    with pytest.raises(ValidationError):
        SyncRun(  # type: ignore[call-arg]
            user_id=uuid4(),
            connection_id=uuid4(),
            trigger=SyncTrigger.USER_PRESENT,
            outcome=SyncRunOutcome.SUCCESS,
            unexpected="x",
        )
