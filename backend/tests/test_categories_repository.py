"""Tests for the category repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic (round amounts, invented names) — see
``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy import Engine, create_engine, select
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.db.base import Base
from traccio.db.models import TransactionRow
from traccio.db.repositories import (
    category_is_confirmed_on_any_transaction,
    category_name_exists,
    create_category,
    delete_category,
    get_category,
    list_categories,
    rename_category,
    seed_default_categories,
    set_confirmed_category,
)
from traccio.domain.categories import DEFAULT_CATEGORY_NAMES
from traccio.domain.enums import KeyStrategy, TransactionStatus
from traccio.domain.models import Category


def _engine() -> Engine:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _category(*, user_id: UUID, name: str = "TEST CATEGORY 01") -> Category:
    return Category(user_id=user_id, name=name)


def _add_tx(
    session: Session,
    *,
    user_id: UUID,
    stable_key: str,
    suggested_category_id: UUID | None = None,
    confirmed_category_id: UUID | None = None,
) -> UUID:
    row = TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=uuid4(),
        amount=-5000,
        currency="EUR",
        booked_at=datetime(2026, 3, 1, tzinfo=UTC),
        value_date=None,
        description="TEST MERCHANT 01",
        display_description=None,
        status=TransactionStatus.BOOKED,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
        suggested_category_id=suggested_category_id,
        confirmed_category_id=confirmed_category_id,
    )
    session.add(row)
    session.commit()
    return row.id


def test_create_get_round_trips() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id, name="Groceries")
        create_category(session, category=category)
        session.commit()

        fetched = get_category(session, user_id=user_id, category_id=category.id)

    assert fetched is not None
    assert fetched.name == "Groceries"


def test_list_categories_is_alphabetical() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        create_category(session, category=_category(user_id=user_id, name="Transport"))
        create_category(session, category=_category(user_id=user_id, name="Groceries"))
        create_category(session, category=_category(user_id=user_id, name="Housing"))
        session.commit()

        listed = list_categories(session, user_id)

    assert [c.name for c in listed] == ["Groceries", "Housing", "Transport"]


def test_list_categories_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        create_category(session, category=_category(user_id=mine, name="MINE"))
        create_category(session, category=_category(user_id=stranger, name="THEIRS"))
        session.commit()

        listed = list_categories(session, mine)

    assert [c.name for c in listed] == ["MINE"]


def test_two_users_may_share_a_category_name() -> None:
    first, second = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        create_category(session, category=_category(user_id=first, name="Groceries"))
        create_category(session, category=_category(user_id=second, name="Groceries"))
        session.commit()  # no IntegrityError: the constraint is per-user

        assert category_name_exists(session, user_id=first, name="Groceries")
        assert category_name_exists(session, user_id=second, name="Groceries")


def test_category_name_exists_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        create_category(session, category=_category(user_id=stranger, name="Groceries"))
        session.commit()

        assert not category_name_exists(session, user_id=mine, name="Groceries")


def test_rename_category() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id, name="Groceries")
        create_category(session, category=category)
        session.commit()

        rename_category(session, user_id=user_id, category_id=category.id, name="Food")
        session.commit()

        fetched = get_category(session, user_id=user_id, category_id=category.id)

    assert fetched is not None
    assert fetched.name == "Food"


def test_rename_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=mine, name="Groceries")
        create_category(session, category=category)
        session.commit()

        # A stranger's user_id cannot rename someone else's category.
        rename_category(session, user_id=stranger, category_id=category.id, name="Hacked")
        session.commit()

        fetched = get_category(session, user_id=mine, category_id=category.id)

    assert fetched is not None
    assert fetched.name == "Groceries"


def test_seed_default_categories_is_idempotent() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        first = seed_default_categories(session, user_id=user_id)
        session.commit()
        second = seed_default_categories(session, user_id=user_id)
        session.commit()

        listed = list_categories(session, user_id)

    assert len(first) == len(DEFAULT_CATEGORY_NAMES)
    assert second == []
    assert len(listed) == len(DEFAULT_CATEGORY_NAMES)


def test_seed_default_categories_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        seed_default_categories(session, user_id=stranger)
        session.commit()

        # Another user having categories does not block my own seeding.
        created = seed_default_categories(session, user_id=mine)
        session.commit()

    assert len(created) == len(DEFAULT_CATEGORY_NAMES)


def test_delete_category_clears_suggested_references() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        create_category(session, category=category)
        session.commit()
        tx = _add_tx(
            session,
            user_id=user_id,
            stable_key="TX-A",
            suggested_category_id=category.id,
        )

        delete_category(session, user_id=user_id, category_id=category.id)
        session.commit()

        surviving = session.scalars(
            select(TransactionRow).where(TransactionRow.id == tx)
        ).one_or_none()

    assert surviving is not None
    assert surviving.suggested_category_id is None


def test_delete_category_leaves_confirmed_references_untouched() -> None:
    """The repository never nulls ``confirmed_category_id``; that refusal is the router's."""
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        create_category(session, category=category)
        session.commit()
        tx = _add_tx(
            session,
            user_id=user_id,
            stable_key="TX-A",
            confirmed_category_id=category.id,
        )

        delete_category(session, user_id=user_id, category_id=category.id)
        session.commit()

        surviving = session.scalars(
            select(TransactionRow).where(TransactionRow.id == tx)
        ).one_or_none()

    assert surviving is not None
    assert surviving.confirmed_category_id == category.id


def test_delete_unknown_category_returns_none() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        deleted = delete_category(session, user_id=user_id, category_id=uuid4())
    assert deleted is None


def test_set_confirmed_category_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=mine)
        create_category(session, category=category)
        session.commit()
        tx = _add_tx(session, user_id=mine, stable_key="TX-A")

        # A stranger's user_id cannot categorize someone else's transaction.
        set_confirmed_category(
            session, user_id=stranger, transaction_id=tx, category_id=category.id
        )
        session.commit()

        surviving = session.scalars(
            select(TransactionRow).where(TransactionRow.id == tx)
        ).one_or_none()

    assert surviving is not None
    assert surviving.confirmed_category_id is None


def test_set_confirmed_category_clears_with_none() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        create_category(session, category=category)
        session.commit()
        tx = _add_tx(session, user_id=user_id, stable_key="TX-A", confirmed_category_id=category.id)

        set_confirmed_category(session, user_id=user_id, transaction_id=tx, category_id=None)
        session.commit()

        surviving = session.scalars(
            select(TransactionRow).where(TransactionRow.id == tx)
        ).one_or_none()

    assert surviving is not None
    assert surviving.confirmed_category_id is None


def test_category_is_confirmed_on_any_transaction_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=mine)
        create_category(session, category=category)
        session.commit()
        _add_tx(session, user_id=mine, stable_key="TX-A", confirmed_category_id=category.id)

        assert category_is_confirmed_on_any_transaction(
            session, user_id=mine, category_id=category.id
        )
        assert not category_is_confirmed_on_any_transaction(
            session, user_id=stranger, category_id=category.id
        )
