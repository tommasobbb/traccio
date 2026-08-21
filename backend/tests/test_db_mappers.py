"""Round-trip tests for the domain <-> ORM mappers.

Pure: no database, no session. They pin the translation, in particular the
:class:`Money` split/join, so a field added on one side without the other is
caught. Fixtures use synthetic values only (see ``.claude/rules/data-safety.md``).
"""

from datetime import UTC, datetime
from uuid import uuid4

from traccio.db.mappers import (
    account_to_row,
    category_to_row,
    connection_to_row,
    row_to_account,
    row_to_category,
    row_to_connection,
    row_to_rule,
    row_to_transaction,
    row_to_user,
    rule_to_row,
    transaction_to_row,
    user_to_row,
)
from traccio.domain.enums import (
    AccountKind,
    ConnectionStatus,
    KeyStrategy,
    RuleMatchKind,
    TransactionStatus,
)
from traccio.domain.models import Account, Category, Connection, Rule, Transaction, User
from traccio.domain.money import Money


def test_user_round_trips() -> None:
    user = User(id=uuid4(), created_at=datetime(2026, 1, 1, tzinfo=UTC))
    assert row_to_user(user_to_row(user)) == user


def test_connection_round_trips() -> None:
    connection = Connection(
        id=uuid4(),
        user_id=uuid4(),
        provider="enable_banking",
        institution_name="TEST BANK 01",
        country="IT",
        status=ConnectionStatus.ACTIVE,
        expires_at=datetime(2026, 6, 1, tzinfo=UTC),
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )
    assert row_to_connection(connection_to_row(connection)) == connection


def test_connection_round_trips_with_no_country() -> None:
    """A connection created before `country` was persisted has it as None."""
    connection = Connection(
        id=uuid4(),
        user_id=uuid4(),
        provider="enable_banking",
        institution_name="LEGACY BANK",
        country=None,
        status=ConnectionStatus.ACTIVE,
        expires_at=None,
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )
    assert row_to_connection(connection_to_row(connection)) == connection


def test_account_round_trips() -> None:
    account = Account(
        id=uuid4(),
        user_id=uuid4(),
        connection_id=uuid4(),
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash="hash-01",
        name="TEST ACCOUNT 01",
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )
    assert row_to_account(account_to_row(account)) == account


def test_transaction_round_trips_and_recomposes_money() -> None:
    transaction = Transaction(
        id=uuid4(),
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-1234, currency="EUR"),
        booked_at=datetime(2026, 2, 1, tzinfo=UTC),
        value_date=datetime(2026, 2, 2, tzinfo=UTC),
        description="TEST MERCHANT 01",
        display_description="Test Merchant",
        status=TransactionStatus.BOOKED,
        entry_reference="ref-01",
        stable_key="key-01",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )

    row = transaction_to_row(transaction)
    # Money is stored split across two columns.
    assert row.amount == -1234
    assert row.currency == "EUR"

    restored = row_to_transaction(row)
    assert restored == transaction
    assert restored.money == Money(amount=-1234, currency="EUR")


def test_transaction_to_row_never_writes_category_ids() -> None:
    """A sync must not be able to set or clear either category id.

    ``transaction_to_row`` is used to build the row for a fresh sync; the only
    writers of ``confirmed_category_id`` and ``suggested_category_id`` are the
    explicit-user-action repository functions (see ``docs/domain.md``
    §Category). This pins that as an executable invariant, not just a comment.
    """
    transaction = Transaction(
        id=uuid4(),
        user_id=uuid4(),
        account_id=uuid4(),
        money=Money(amount=-1234, currency="EUR"),
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        stable_key="key-01",
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
        suggested_category_id=uuid4(),
        confirmed_category_id=uuid4(),
    )

    row = transaction_to_row(transaction)

    assert row.suggested_category_id is None
    assert row.confirmed_category_id is None


def test_row_to_transaction_carries_category_ids() -> None:
    """Unlike ``transaction_to_row``, reading a row does surface both ids."""
    suggested = uuid4()
    confirmed = uuid4()
    row = transaction_to_row(
        Transaction(
            id=uuid4(),
            user_id=uuid4(),
            account_id=uuid4(),
            money=Money(amount=-1234, currency="EUR"),
            description="TEST MERCHANT 01",
            status=TransactionStatus.BOOKED,
            stable_key="key-01",
            key_strategy=KeyStrategy.ENTRY_REFERENCE,
        )
    )
    row.suggested_category_id = suggested
    row.confirmed_category_id = confirmed

    restored = row_to_transaction(row)

    assert restored.suggested_category_id == suggested
    assert restored.confirmed_category_id == confirmed


def test_category_round_trips() -> None:
    category = Category(
        id=uuid4(),
        user_id=uuid4(),
        name="Groceries",
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )
    assert row_to_category(category_to_row(category)) == category


def test_rule_round_trips() -> None:
    rule = Rule(
        id=uuid4(),
        user_id=uuid4(),
        category_id=uuid4(),
        match_kind=RuleMatchKind.CONTAINS,
        pattern="TEST MERCHANT 01",
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )
    assert row_to_rule(rule_to_row(rule)) == rule
