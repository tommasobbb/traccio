"""Tests for the transfer/dismissal repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic (round amounts, invented ids) — see
``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _engine
from traccio.db.models import TransactionRow
from traccio.db.repositories import (
    create_transfer,
    create_transfer_dismissal,
    delete_transfer,
    get_transaction,
    list_transfer_dismissals,
    list_transfers,
    set_transaction_role,
    transfer_exists_for_transaction,
)
from traccio.domain.enums import KeyStrategy, TransactionRole, TransactionStatus
from traccio.domain.models import Transfer


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
        role=TransactionRole.PERSONAL,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )
    session.add(row)
    session.commit()
    return row.id


def test_create_and_list_transfer_round_trips() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        out_id = _add_tx(session, user_id=user_id, amount=-50000, stable_key="TX-OUT")
        in_id = _add_tx(session, user_id=user_id, amount=50000, stable_key="TX-IN")
        transfer = Transfer(
            user_id=user_id, outgoing_transaction_id=out_id, incoming_transaction_id=in_id
        )
        create_transfer(session, transfer=transfer)
        session.commit()

        [listed] = list_transfers(session, user_id)
        assert listed.outgoing_transaction_id == out_id
        assert listed.incoming_transaction_id == in_id
        assert transfer_exists_for_transaction(session, user_id=user_id, transaction_id=out_id)
        assert transfer_exists_for_transaction(session, user_id=user_id, transaction_id=in_id)


def test_delete_transfer_returns_it_and_is_user_scoped() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        out_id = _add_tx(session, user_id=user_id, amount=-50000, stable_key="TX-OUT")
        in_id = _add_tx(session, user_id=user_id, amount=50000, stable_key="TX-IN")
        transfer = Transfer(
            user_id=user_id, outgoing_transaction_id=out_id, incoming_transaction_id=in_id
        )
        create_transfer(session, transfer=transfer)
        session.commit()

        # Another user cannot delete it.
        assert delete_transfer(session, user_id=uuid4(), transfer_id=transfer.id) is None
        assert list_transfers(session, user_id) != []

        deleted = delete_transfer(session, user_id=user_id, transfer_id=transfer.id)
        session.commit()
        assert deleted is not None
        assert deleted.id == transfer.id
        assert list_transfers(session, user_id) == []


def test_set_transaction_role_is_user_scoped() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        tx_id = _add_tx(session, user_id=user_id, amount=-50000, stable_key="TX-OUT")

        # A stranger's update touches nothing.
        set_transaction_role(
            session, user_id=uuid4(), transaction_id=tx_id, role=TransactionRole.TRANSFER
        )
        session.commit()
        unchanged = get_transaction(session, user_id=user_id, transaction_id=tx_id)
        assert unchanged is not None
        assert unchanged.role is TransactionRole.PERSONAL

        set_transaction_role(
            session, user_id=user_id, transaction_id=tx_id, role=TransactionRole.TRANSFER
        )
        session.commit()
        changed = get_transaction(session, user_id=user_id, transaction_id=tx_id)
        assert changed is not None
        assert changed.role is TransactionRole.TRANSFER


def test_dismissal_is_order_independent_and_idempotent() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        a = _add_tx(session, user_id=user_id, amount=-50000, stable_key="TX-A")
        b = _add_tx(session, user_id=user_id, amount=50000, stable_key="TX-B")

        create_transfer_dismissal(session, user_id=user_id, transaction_id_a=a, transaction_id_b=b)
        session.commit()
        # Same pair in the opposite order does not create a second row.
        create_transfer_dismissal(session, user_id=user_id, transaction_id_a=b, transaction_id_b=a)
        session.commit()

        dismissals = list_transfer_dismissals(session, user_id)
        assert dismissals == frozenset({frozenset({a, b})})


def test_dismissals_are_user_scoped() -> None:
    user_id, stranger_id = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        a = _add_tx(session, user_id=user_id, amount=-50000, stable_key="TX-A")
        b = _add_tx(session, user_id=user_id, amount=50000, stable_key="TX-B")
        create_transfer_dismissal(session, user_id=user_id, transaction_id_a=a, transaction_id_b=b)
        session.commit()

        assert list_transfer_dismissals(session, stranger_id) == frozenset()
