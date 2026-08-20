"""Tests for the advance repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic (round amounts, invented names) — see
``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.db.base import Base
from traccio.db.models import TransactionRow
from traccio.db.repositories import (
    advance_exists_for_transaction,
    create_advance,
    delete_advance,
    get_advance,
    list_advances,
)
from traccio.domain.enums import KeyStrategy, TransactionStatus
from traccio.domain.models import Advance, Money, Participant


def _engine() -> Engine:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _add_tx(session: Session, *, user_id: UUID, amount: int, stable_key: str) -> UUID:
    row = TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=uuid4(),
        amount=amount,
        currency="EUR",
        booked_at=datetime(2026, 3, 1, tzinfo=UTC),
        value_date=None,
        description="TEST MERCHANT 01",
        display_description=None,
        status=TransactionStatus.BOOKED,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )
    session.add(row)
    session.commit()
    return row.id


def _advance(*, user_id: UUID, transaction_id: UUID, with_participants: bool = False) -> Advance:
    participants = (
        [Participant(name="TEST FRIEND 01", expected_amount=Money(amount=2000, currency="EUR"))]
        if with_participants
        else []
    )
    return Advance(
        user_id=user_id,
        transaction_id=transaction_id,
        own_share=Money(amount=1000, currency="EUR"),
        participants=participants,
    )


def test_create_get_round_trips_with_participants() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        tx_id = _add_tx(session, user_id=user_id, amount=-5000, stable_key="TX-01")
        advance = _advance(user_id=user_id, transaction_id=tx_id, with_participants=True)
        create_advance(session, advance=advance)
        session.commit()

        fetched = get_advance(session, user_id=user_id, advance_id=advance.id)
        assert fetched is not None
        assert fetched.transaction_id == tx_id
        assert fetched.own_share == Money(amount=1000, currency="EUR")
        assert [p.name for p in fetched.participants] == ["TEST FRIEND 01"]
        assert fetched.participants[0].expected_amount == Money(amount=2000, currency="EUR")


def test_list_and_exists_are_user_scoped() -> None:
    user_id, stranger_id = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        tx_id = _add_tx(session, user_id=user_id, amount=-5000, stable_key="TX-01")
        advance = _advance(user_id=user_id, transaction_id=tx_id)
        create_advance(session, advance=advance)
        session.commit()

        assert len(list_advances(session, user_id)) == 1
        assert list_advances(session, stranger_id) == []
        assert advance_exists_for_transaction(session, user_id=user_id, transaction_id=tx_id)
        assert not advance_exists_for_transaction(
            session, user_id=stranger_id, transaction_id=tx_id
        )


def test_delete_returns_advance_and_removes_participants() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        tx_id = _add_tx(session, user_id=user_id, amount=-5000, stable_key="TX-01")
        advance = _advance(user_id=user_id, transaction_id=tx_id, with_participants=True)
        create_advance(session, advance=advance)
        session.commit()

        # A stranger cannot delete it.
        assert delete_advance(session, user_id=uuid4(), advance_id=advance.id) is None
        assert list_advances(session, user_id) != []

        deleted = delete_advance(session, user_id=user_id, advance_id=advance.id)
        session.commit()
        assert deleted is not None
        assert deleted.id == advance.id
        assert list_advances(session, user_id) == []
        # Participants are gone with the parent.
        assert get_advance(session, user_id=user_id, advance_id=advance.id) is None
