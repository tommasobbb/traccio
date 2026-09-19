"""Tests for the reimbursement repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic (round amounts, invented names) — see
``docs/engineering.md``.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _engine
from traccio.db.models import TransactionRow
from traccio.db.repositories import (
    create_advance,
    create_reimbursement,
    delete_reimbursement,
    get_advance,
    list_reimbursements,
    set_advance_status,
    sum_reimbursements_by_advance,
)
from traccio.domain.enums import AdvanceStatus, KeyStrategy, TransactionStatus
from traccio.domain.models import Advance, Money, Reimbursement


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


def _advance(session: Session, *, user_id: UUID) -> Advance:
    tx_id = _add_tx(session, user_id=user_id, amount=-5000, stable_key="TX-01")
    advance = Advance(
        user_id=user_id,
        transaction_id=tx_id,
        own_share=Money(amount=1000, currency="EUR"),
    )
    create_advance(session, advance=advance)
    session.commit()
    return advance


def _reimbursement(
    *, user_id: UUID, advance_id: UUID, amount: int, transaction_id: UUID | None = None
) -> Reimbursement:
    return Reimbursement(
        user_id=user_id,
        advance_id=advance_id,
        amount=Money(amount=amount, currency="EUR"),
        transaction_id=transaction_id,
    )


def test_create_list_and_sum_are_user_scoped() -> None:
    user_id, stranger_id = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        advance = _advance(session, user_id=user_id)
        create_reimbursement(
            session,
            reimbursement=_reimbursement(user_id=user_id, advance_id=advance.id, amount=1500),
        )
        create_reimbursement(
            session,
            reimbursement=_reimbursement(user_id=user_id, advance_id=advance.id, amount=500),
        )
        session.commit()

        listed = list_reimbursements(session, user_id=user_id, advance_id=advance.id)
        assert [r.amount.amount for r in listed] == [1500, 500]
        assert list_reimbursements(session, user_id=stranger_id, advance_id=advance.id) == []

        totals = sum_reimbursements_by_advance(session, user_id)
        assert totals[advance.id] == Money(amount=2000, currency="EUR")
        assert sum_reimbursements_by_advance(session, stranger_id) == {}


def test_delete_returns_reimbursement_and_is_scoped() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        advance = _advance(session, user_id=user_id)
        reimbursement = _reimbursement(user_id=user_id, advance_id=advance.id, amount=1500)
        create_reimbursement(session, reimbursement=reimbursement)
        session.commit()

        # A stranger cannot delete it.
        assert (
            delete_reimbursement(
                session,
                user_id=uuid4(),
                advance_id=advance.id,
                reimbursement_id=reimbursement.id,
            )
            is None
        )

        deleted = delete_reimbursement(
            session, user_id=user_id, advance_id=advance.id, reimbursement_id=reimbursement.id
        )
        session.commit()
        assert deleted is not None
        assert deleted.id == reimbursement.id
        assert list_reimbursements(session, user_id=user_id, advance_id=advance.id) == []


def test_set_advance_status_is_scoped() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        advance = _advance(session, user_id=user_id)

        # A stranger's write is a no-op.
        set_advance_status(
            session, user_id=uuid4(), advance_id=advance.id, status=AdvanceStatus.WRITTEN_OFF
        )
        session.commit()
        unchanged = get_advance(session, user_id=user_id, advance_id=advance.id)
        assert unchanged is not None and unchanged.status is AdvanceStatus.OPEN

        set_advance_status(
            session, user_id=user_id, advance_id=advance.id, status=AdvanceStatus.WRITTEN_OFF
        )
        session.commit()
        written_off = get_advance(session, user_id=user_id, advance_id=advance.id)
        assert written_off is not None and written_off.status is AdvanceStatus.WRITTEN_OFF
