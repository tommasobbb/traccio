"""Tests for the rule repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic (round amounts, invented patterns) — see
``.claude/rules/data-safety.md``.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _engine
from traccio.db.mappers import category_to_row
from traccio.db.models import RuleRow, TransactionRow
from traccio.db.repositories import (
    create_category,
    create_rule,
    delete_category,
    delete_rule,
    get_rule,
    list_rules,
    rule_exists,
    set_suggested_categories,
)
from traccio.domain.enums import KeyStrategy, RuleMatchKind, TransactionStatus
from traccio.domain.models import Category, Rule


def _category(*, user_id: UUID, name: str = "TEST CATEGORY 01") -> Category:
    return Category(user_id=user_id, name=name)


def _rule(
    *,
    user_id: UUID,
    category_id: UUID,
    match_kind: RuleMatchKind = RuleMatchKind.CONTAINS,
    pattern: str = "TEST MERCHANT 01",
) -> Rule:
    return Rule(user_id=user_id, category_id=category_id, match_kind=match_kind, pattern=pattern)


def _add_tx(
    session: Session,
    *,
    user_id: UUID,
    stable_key: str,
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
        confirmed_category_id=confirmed_category_id,
    )
    session.add(row)
    session.commit()
    return row.id


def test_create_get_round_trips() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        session.add(category_to_row(category))
        session.commit()

        rule = _rule(user_id=user_id, category_id=category.id)
        create_rule(session, rule=rule)
        session.commit()

        fetched = get_rule(session, user_id=user_id, rule_id=rule.id)

    assert fetched is not None
    assert fetched.pattern == "TEST MERCHANT 01"
    assert fetched.match_kind is RuleMatchKind.CONTAINS


def test_get_rule_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=stranger)
        session.add(category_to_row(category))
        session.commit()
        rule = _rule(user_id=stranger, category_id=category.id)
        create_rule(session, rule=rule)
        session.commit()

        assert get_rule(session, user_id=mine, rule_id=rule.id) is None


def test_list_rules_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        mine_category = _category(user_id=mine)
        theirs_category = _category(user_id=stranger)
        session.add(category_to_row(mine_category))
        session.add(category_to_row(theirs_category))
        session.commit()
        create_rule(session, rule=_rule(user_id=mine, category_id=mine_category.id, pattern="MINE"))
        create_rule(
            session, rule=_rule(user_id=stranger, category_id=theirs_category.id, pattern="THEIRS")
        )
        session.commit()

        listed = list_rules(session, mine)

    assert [r.pattern for r in listed] == ["MINE"]


def test_rule_exists_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=stranger)
        session.add(category_to_row(category))
        session.commit()
        create_rule(
            session,
            rule=_rule(
                user_id=stranger,
                category_id=category.id,
                match_kind=RuleMatchKind.CONTAINS,
                pattern="TEST",
            ),
        )
        session.commit()

        assert not rule_exists(
            session, user_id=mine, match_kind=RuleMatchKind.CONTAINS, pattern="TEST"
        )
        assert rule_exists(
            session, user_id=stranger, match_kind=RuleMatchKind.CONTAINS, pattern="TEST"
        )


def test_rule_exists_distinguishes_match_kind() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        session.add(category_to_row(category))
        session.commit()
        create_rule(
            session,
            rule=_rule(
                user_id=user_id,
                category_id=category.id,
                match_kind=RuleMatchKind.CONTAINS,
                pattern="TEST",
            ),
        )
        session.commit()

        assert not rule_exists(
            session, user_id=user_id, match_kind=RuleMatchKind.EQUALS, pattern="TEST"
        )


def test_delete_rule() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        session.add(category_to_row(category))
        session.commit()
        rule = _rule(user_id=user_id, category_id=category.id)
        create_rule(session, rule=rule)
        session.commit()

        deleted = delete_rule(session, user_id=user_id, rule_id=rule.id)
        session.commit()
        surviving = get_rule(session, user_id=user_id, rule_id=rule.id)

    assert deleted is not None
    assert surviving is None


def test_delete_rule_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=mine)
        session.add(category_to_row(category))
        session.commit()
        rule = _rule(user_id=mine, category_id=category.id)
        create_rule(session, rule=rule)
        session.commit()

        # A stranger's user_id cannot delete someone else's rule.
        deleted = delete_rule(session, user_id=stranger, rule_id=rule.id)
        session.commit()
        surviving = get_rule(session, user_id=mine, rule_id=rule.id)

    assert deleted is None
    assert surviving is not None


def test_delete_unknown_rule_returns_none() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        assert delete_rule(session, user_id=user_id, rule_id=uuid4()) is None


def test_set_suggested_categories_writes_and_clears_in_bulk() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        create_category(session, category=category)
        session.commit()
        matched_tx = _add_tx(session, user_id=user_id, stable_key="TX-A")
        cleared_tx = _add_tx(session, user_id=user_id, stable_key="TX-B")

        matched, cleared = set_suggested_categories(
            session,
            user_id=user_id,
            assignments={matched_tx: category.id, cleared_tx: None},
        )
        session.commit()

        rows = {
            row.id: row
            for row in session.scalars(
                select(TransactionRow).where(TransactionRow.user_id == user_id)
            ).all()
        }

    assert (matched, cleared) == (1, 1)
    assert rows[matched_tx].suggested_category_id == category.id
    assert rows[cleared_tx].suggested_category_id is None


def test_set_suggested_categories_never_touches_confirmed_category() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        suggested = _category(user_id=user_id, name="Suggested")
        confirmed = _category(user_id=user_id, name="Confirmed")
        create_category(session, category=suggested)
        create_category(session, category=confirmed)
        session.commit()
        tx = _add_tx(
            session, user_id=user_id, stable_key="TX-A", confirmed_category_id=confirmed.id
        )

        set_suggested_categories(session, user_id=user_id, assignments={tx: suggested.id})
        session.commit()

        row = session.scalars(select(TransactionRow).where(TransactionRow.id == tx)).one()

    assert row.suggested_category_id == suggested.id
    assert row.confirmed_category_id == confirmed.id


def test_set_suggested_categories_is_user_scoped() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=mine)
        create_category(session, category=category)
        session.commit()
        tx = _add_tx(session, user_id=mine, stable_key="TX-A")

        # A stranger's user_id cannot categorize someone else's transaction.
        set_suggested_categories(session, user_id=stranger, assignments={tx: category.id})
        session.commit()

        row = session.scalars(select(TransactionRow).where(TransactionRow.id == tx)).one()

    assert row.suggested_category_id is None


def test_delete_category_deletes_its_rules() -> None:
    user_id = uuid4()
    engine = _engine()
    with Session(engine) as session:
        category = _category(user_id=user_id)
        create_category(session, category=category)
        session.commit()
        rule = _rule(user_id=user_id, category_id=category.id)
        create_rule(session, rule=rule)
        session.commit()

        delete_category(session, user_id=user_id, category_id=category.id)
        session.commit()

        surviving = session.scalars(select(RuleRow).where(RuleRow.id == rule.id)).one_or_none()

    assert surviving is None


def test_delete_category_leaves_other_users_rules_alone() -> None:
    mine, stranger = uuid4(), uuid4()
    engine = _engine()
    with Session(engine) as session:
        mine_category = _category(user_id=mine)
        theirs_category = _category(user_id=stranger)
        create_category(session, category=mine_category)
        create_category(session, category=theirs_category)
        session.commit()
        theirs_rule = _rule(user_id=stranger, category_id=theirs_category.id)
        create_rule(session, rule=theirs_rule)
        session.commit()

        delete_category(session, user_id=mine, category_id=mine_category.id)
        session.commit()
        surviving = get_rule(session, user_id=stranger, rule_id=theirs_rule.id)

    assert surviving is not None
