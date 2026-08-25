"""Tests for the rule endpoints, including ``POST /rules/apply``.

The app is built via the factory and its ``get_session`` dependency is overridden
to a shared in-memory SQLite engine, so the endpoints are exercised end to end
without a running PostgreSQL. Values are synthetic (see
``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.base import Base
from traccio.db.mappers import rule_to_row
from traccio.db.models import CategoryRow, TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, PaletteColor, RuleMatchKind, TransactionStatus
from traccio.domain.models import Rule

_DAY = datetime(2026, 3, 1, tzinfo=UTC)


def _client(engine: Engine) -> TestClient:
    def override_get_session() -> Iterator[Session]:
        session = Session(engine)
        try:
            yield session
        finally:
            session.close()

    app = create_app()
    app.dependency_overrides[get_session] = override_get_session
    return TestClient(app)


def _sqlite_engine() -> Engine:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    return engine


def _seed_tx(
    engine: Engine,
    *,
    user_id: UUID,
    stable_key: str = "TX-A",
    description: str = "TEST MERCHANT 01",
) -> str:
    with Session(engine) as session:
        tx = TransactionRow(
            id=uuid4(),
            user_id=user_id,
            account_id=uuid4(),
            amount=-5000,
            currency="EUR",
            booked_at=_DAY,
            value_date=_DAY,
            description=description,
            display_description=None,
            status=TransactionStatus.BOOKED,
            entry_reference=stable_key,
            stable_key=stable_key,
            key_strategy=KeyStrategy.ENTRY_REFERENCE,
        )
        session.add(tx)
        session.commit()
        return str(tx.id)


def _seed_category(
    engine: Engine, *, user_id: UUID, name: str = "TEST CATEGORY 01", parent_id: UUID | None = None
) -> str:
    with Session(engine) as session:
        row = CategoryRow(
            id=uuid4(),
            user_id=user_id,
            name=name,
            parent_id=parent_id,
            color=PaletteColor.SLATE,
            created_at=_DAY,
        )
        session.add(row)
        session.commit()
        return str(row.id)


def test_create_rule() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "MERCHANT"}
    )

    assert response.status_code == 201
    body = response.json()
    assert body["category_id"] == category_id
    assert body["match_kind"] == "contains"
    assert body["pattern"] == "MERCHANT"


def test_create_rule_strips_the_pattern() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(
        "/rules",
        json={"category_id": category_id, "match_kind": "contains", "pattern": "  MERCHANT  "},
    )

    assert response.json()["pattern"] == "MERCHANT"


def test_create_rule_unknown_category_is_404() -> None:
    client = _client(_sqlite_engine())

    response = client.post(
        "/rules",
        json={"category_id": str(uuid4()), "match_kind": "contains", "pattern": "MERCHANT"},
    )

    assert response.status_code == 404
    assert response.json()["detail"] == "unknown category"


def test_create_rule_blank_pattern_is_422() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "   "}
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "blank_pattern"


def test_duplicate_rule_is_refused() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)
    client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "MERCHANT"}
    )

    response = client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "MERCHANT"}
    )

    assert response.status_code == 409
    assert response.json()["detail"] == "rule_already_exists"


def test_same_pattern_different_match_kind_is_allowed() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)
    client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "MERCHANT"}
    )

    response = client.post(
        "/rules", json={"category_id": category_id, "match_kind": "equals", "pattern": "MERCHANT"}
    )

    assert response.status_code == 201


def test_list_rules_in_evaluation_order() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)
    client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "AMAZON"}
    )
    client.post(
        "/rules",
        json={"category_id": category_id, "match_kind": "contains", "pattern": "AMAZON PRIME"},
    )

    response = client.get("/rules")

    patterns = [r["pattern"] for r in response.json()["rules"]]
    assert patterns == ["AMAZON PRIME", "AMAZON"]


def test_delete_rule() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)
    rule_id = client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "MERCHANT"}
    ).json()["id"]

    assert client.delete(f"/rules/{rule_id}").status_code == 204
    assert client.get("/rules").json()["rules"] == []


def test_delete_unknown_rule_is_404() -> None:
    assert _client(_sqlite_engine()).delete(f"/rules/{uuid4()}").status_code == 404


def test_cannot_delete_another_users_rule() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=stranger_id)
    with Session(engine) as session:
        theirs = Rule(
            user_id=stranger_id,
            category_id=UUID(category_id),
            match_kind=RuleMatchKind.CONTAINS,
            pattern="MERCHANT",
        )
        session.add(rule_to_row(theirs))
        session.commit()
        rule_id = str(theirs.id)
    client = _client(engine)

    response = client.delete(f"/rules/{rule_id}")

    assert response.status_code == 404


def test_apply_sets_suggested_category_on_a_match() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id, description="TEST MERCHANT 01")
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)
    client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "MERCHANT"}
    )

    response = client.post("/rules/apply")

    assert response.status_code == 200
    body = response.json()
    assert body == {"rules_applied": 1, "matched": 1, "cleared": 0}

    [projected] = client.get("/transactions").json()["transactions"]
    assert projected["id"] == tx
    assert projected["suggested_category_id"] == category_id
    assert projected["effective_category_id"] == category_id


def test_apply_sets_suggested_category_when_the_rule_targets_a_child_category() -> None:
    """A rule may target a child category, not just a root — no special case."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id, description="TEST MERCHANT 01")
    root_id = _seed_category(engine, user_id=dev_user_id, name="Subscriptions")
    child_id = _seed_category(
        engine, user_id=dev_user_id, name="Streaming", parent_id=UUID(root_id)
    )
    client = _client(engine)
    client.post(
        "/rules", json={"category_id": child_id, "match_kind": "contains", "pattern": "MERCHANT"}
    )

    response = client.post("/rules/apply")

    assert response.status_code == 200
    assert response.json() == {"rules_applied": 1, "matched": 1, "cleared": 0}
    [projected] = client.get("/transactions").json()["transactions"]
    assert projected["id"] == tx
    assert projected["suggested_category_id"] == child_id


def test_apply_clears_a_stale_suggestion_from_a_deleted_rule() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id, description="TEST MERCHANT 01")
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)
    rule_id = client.post(
        "/rules", json={"category_id": category_id, "match_kind": "contains", "pattern": "MERCHANT"}
    ).json()["id"]
    client.post("/rules/apply")
    [projected] = client.get("/transactions").json()["transactions"]
    assert projected["suggested_category_id"] == category_id

    client.delete(f"/rules/{rule_id}")
    response = client.post("/rules/apply")

    assert response.json() == {"rules_applied": 0, "matched": 0, "cleared": 1}
    [projected] = client.get("/transactions").json()["transactions"]
    assert projected["suggested_category_id"] is None


def test_apply_does_not_touch_a_confirmed_category() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id, description="TEST MERCHANT 01")
    suggested_category = _seed_category(engine, user_id=dev_user_id, name="Suggested")
    confirmed_category = _seed_category(engine, user_id=dev_user_id, name="Confirmed")
    client = _client(engine)
    client.post(f"/transactions/{tx}/category", json={"category_id": confirmed_category})
    client.post(
        "/rules",
        json={
            "category_id": suggested_category,
            "match_kind": "contains",
            "pattern": "MERCHANT",
        },
    )

    client.post("/rules/apply")

    [projected] = client.get("/transactions").json()["transactions"]
    assert projected["suggested_category_id"] == suggested_category
    assert projected["confirmed_category_id"] == confirmed_category
    assert projected["effective_category_id"] == confirmed_category


def test_apply_with_no_rules_clears_everything() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post("/rules/apply")

    assert response.json() == {"rules_applied": 0, "matched": 0, "cleared": 1}
