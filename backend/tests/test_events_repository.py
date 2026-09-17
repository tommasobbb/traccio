"""Tests for the event repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic (round amounts, invented names) — see
``.claude/rules/data-safety.md``.
"""

from datetime import UTC, date, datetime
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _engine
from traccio.db.models import TransactionRow
from traccio.db.repositories import (
    assign_transaction_to_event,
    create_event,
    delete_event,
    get_event,
    get_transaction_event_id,
    list_event_members,
    list_events,
    set_event_status,
    unassign_transaction_from_event,
)
from traccio.domain.enums import EventStatus, KeyStrategy, TransactionStatus
from traccio.domain.models import Event


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


def _event(*, user_id: UUID, name: str = "TEST TRIP 01") -> Event:
    return Event(
        user_id=user_id,
        name=name,
        start_date=date(2026, 3, 1),
        end_date=date(2026, 3, 8),
    )


def test_create_get_round_trips_with_dates_and_status() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        event = _event(user_id=user_id)
        create_event(session, event=event)
        session.commit()

        fetched = get_event(session, user_id=user_id, event_id=event.id)

    assert fetched is not None
    assert fetched.name == "TEST TRIP 01"
    assert fetched.start_date == date(2026, 3, 1)
    assert fetched.end_date == date(2026, 3, 8)
    assert fetched.status is EventStatus.ACTIVE


def test_list_events_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        create_event(session, event=_event(user_id=mine, name="MINE"))
        create_event(session, event=_event(user_id=stranger, name="THEIRS"))
        session.commit()

        listed = list_events(session, mine)

    assert [e.name for e in listed] == ["MINE"]


def test_assign_and_list_members() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        event = _event(user_id=user_id)
        create_event(session, event=event)
        session.commit()
        tx_a = _add_tx(session, user_id=user_id, amount=-5000, stable_key="TX-A")
        tx_b = _add_tx(session, user_id=user_id, amount=-2500, stable_key="TX-B")

        assign_transaction_to_event(
            session, user_id=user_id, event_id=event.id, transaction_id=tx_a
        )
        assign_transaction_to_event(
            session, user_id=user_id, event_id=event.id, transaction_id=tx_b
        )
        session.commit()

        members = list_event_members(session, user_id=user_id, event_id=event.id)
        assert {m.id for m in members} == {tx_a, tx_b}
        assert get_transaction_event_id(session, user_id=user_id, transaction_id=tx_a) == event.id


def test_unassign_clears_membership_only_for_this_event() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        event = _event(user_id=user_id)
        other = _event(user_id=user_id, name="OTHER")
        create_event(session, event=event)
        create_event(session, event=other)
        session.commit()
        tx = _add_tx(session, user_id=user_id, amount=-5000, stable_key="TX-A")
        assign_transaction_to_event(session, user_id=user_id, event_id=event.id, transaction_id=tx)
        session.commit()

        # Unassigning from the wrong event is a no-op.
        unassign_transaction_from_event(
            session, user_id=user_id, event_id=other.id, transaction_id=tx
        )
        session.commit()
        assert get_transaction_event_id(session, user_id=user_id, transaction_id=tx) == event.id

        # Unassigning from the right event clears it.
        unassign_transaction_from_event(
            session, user_id=user_id, event_id=event.id, transaction_id=tx
        )
        session.commit()
        assert get_transaction_event_id(session, user_id=user_id, transaction_id=tx) is None


def test_delete_event_clears_members_and_keeps_transactions() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        event = _event(user_id=user_id)
        create_event(session, event=event)
        session.commit()
        tx = _add_tx(session, user_id=user_id, amount=-5000, stable_key="TX-A")
        assign_transaction_to_event(session, user_id=user_id, event_id=event.id, transaction_id=tx)
        session.commit()

        deleted = delete_event(session, user_id=user_id, event_id=event.id)
        session.commit()

        assert deleted is not None
        assert deleted.id == event.id
        assert get_event(session, user_id=user_id, event_id=event.id) is None
        # The transaction survives, no longer grouped.
        surviving = session.scalars(
            select(TransactionRow).where(TransactionRow.id == tx)
        ).one_or_none()
        assert surviving is not None
        assert surviving.event_id is None


def test_set_event_status() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        event = _event(user_id=user_id)
        create_event(session, event=event)
        session.commit()

        set_event_status(session, user_id=user_id, event_id=event.id, status=EventStatus.CLOSED)
        session.commit()

        fetched = get_event(session, user_id=user_id, event_id=event.id)
        assert fetched is not None
        assert fetched.status is EventStatus.CLOSED


def test_get_event_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        theirs = _event(user_id=stranger)
        create_event(session, event=theirs)
        session.commit()

        # The stranger's event is invisible to another user.
        assert get_event(session, user_id=mine, event_id=theirs.id) is None
