"""Schema-level invariant tests.

Exercised against an in-memory SQLite database — enough to create the tables
and prove the unique constraints reject duplicates, without needing a running
PostgreSQL server. Type differences between SQLite and PostgreSQL (UUID, tz)
are irrelevant to what these tests assert. The real migration is verified on
PostgreSQL (see the plan's verification section). Values are synthetic.
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import uuid4

import pytest
from sqlalchemy import create_engine
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from traccio.db.base import Base
from traccio.db.models import AccountRow, CategoryRow, TransactionRow
from traccio.domain.enums import (
    AccountKind,
    KeyStrategy,
    TransactionStatus,
)


@pytest.fixture
def session() -> Iterator[Session]:
    """Provide a session backed by a fresh in-memory SQLite schema."""
    engine = create_engine("sqlite://")
    Base.metadata.create_all(engine)
    with Session(engine) as session:
        yield session


def _account(user_id: object, identification_hash: str) -> AccountRow:
    return AccountRow(
        id=uuid4(),
        user_id=user_id,
        connection_id=uuid4(),
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash=identification_hash,
        name="TEST ACCOUNT 01",
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )


def _transaction(account_id: object, stable_key: str) -> TransactionRow:
    return TransactionRow(
        id=uuid4(),
        user_id=uuid4(),
        account_id=account_id,
        amount=-1234,
        currency="EUR",
        description="TEST MERCHANT 01",
        status=TransactionStatus.BOOKED,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def test_duplicate_stable_key_per_account_is_rejected(session: Session) -> None:
    """Same (account_id, stable_key) twice violates the sync-idempotency uq."""
    account_id = uuid4()
    session.add(_transaction(account_id, "key-01"))
    session.add(_transaction(account_id, "key-01"))
    with pytest.raises(IntegrityError):
        session.commit()


def test_duplicate_account_identity_per_user_is_rejected(session: Session) -> None:
    """Same (user_id, identification_hash) twice violates the account-identity uq."""
    user_id = uuid4()
    session.add(_account(user_id, "hash-01"))
    session.add(_account(user_id, "hash-01"))
    with pytest.raises(IntegrityError):
        session.commit()


def test_duplicate_category_name_per_user_is_rejected(session: Session) -> None:
    """Same (user_id, name) twice violates the category-name uq."""
    user_id = uuid4()
    now = datetime(2026, 1, 1, tzinfo=UTC)
    session.add(CategoryRow(id=uuid4(), user_id=user_id, name="Groceries", created_at=now))
    session.add(CategoryRow(id=uuid4(), user_id=user_id, name="Groceries", created_at=now))
    with pytest.raises(IntegrityError):
        session.commit()


def test_same_category_name_for_two_users_is_accepted(session: Session) -> None:
    """The uniqueness is per user, not global."""
    now = datetime(2026, 1, 1, tzinfo=UTC)
    session.add(CategoryRow(id=uuid4(), user_id=uuid4(), name="Groceries", created_at=now))
    session.add(CategoryRow(id=uuid4(), user_id=uuid4(), name="Groceries", created_at=now))
    session.commit()  # does not raise
