"""Tests for the category endpoints, and the transaction category confirm/clear.

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
from traccio.db.models import CategoryRow, TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, TransactionStatus

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


def _seed_tx(engine: Engine, *, user_id: UUID, stable_key: str = "TX-A") -> str:
    with Session(engine) as session:
        tx = TransactionRow(
            id=uuid4(),
            user_id=user_id,
            account_id=uuid4(),
            amount=-5000,
            currency="EUR",
            booked_at=_DAY,
            value_date=_DAY,
            description="TEST MERCHANT 01",
            display_description=None,
            status=TransactionStatus.BOOKED,
            entry_reference=stable_key,
            stable_key=stable_key,
            key_strategy=KeyStrategy.ENTRY_REFERENCE,
        )
        session.add(tx)
        session.commit()
        return str(tx.id)


def _seed_category(engine: Engine, *, user_id: UUID, name: str = "TEST CATEGORY 01") -> str:
    with Session(engine) as session:
        row = CategoryRow(id=uuid4(), user_id=user_id, name=name, created_at=_DAY)
        session.add(row)
        session.commit()
        return str(row.id)


def test_create_category() -> None:
    client = _client(_sqlite_engine())

    response = client.post("/categories", json={"name": "Groceries"})

    assert response.status_code == 201
    assert response.json()["name"] == "Groceries"


def test_create_category_strips_the_name() -> None:
    client = _client(_sqlite_engine())

    response = client.post("/categories", json={"name": "  Groceries  "})

    assert response.json()["name"] == "Groceries"


def test_duplicate_name_is_refused() -> None:
    client = _client(_sqlite_engine())
    client.post("/categories", json={"name": "Groceries"})

    response = client.post("/categories", json={"name": "Groceries"})

    assert response.status_code == 409
    assert response.json()["detail"] == "category_name_taken"


def test_blank_name_is_refused() -> None:
    client = _client(_sqlite_engine())

    response = client.post("/categories", json={"name": "   "})

    assert response.status_code == 422
    assert response.json()["detail"] == "blank_name"


def test_list_categories_alphabetically() -> None:
    client = _client(_sqlite_engine())
    client.post("/categories", json={"name": "Transport"})
    client.post("/categories", json={"name": "Groceries"})

    response = client.get("/categories")

    assert [c["name"] for c in response.json()["categories"]] == ["Groceries", "Transport"]


def test_seed_defaults_is_idempotent() -> None:
    client = _client(_sqlite_engine())

    first = client.post("/categories/defaults").json()["categories"]
    second = client.post("/categories/defaults").json()["categories"]

    assert len(first) > 0
    assert len(second) == len(first)


def test_seed_defaults_does_not_resurrect_a_category_deleted_while_others_remain() -> None:
    """The "only if empty" guard protects a *partial* deletion from resurrection.

    It does not (and is not meant to) protect a user who deletes every single
    category — at that point they genuinely have zero, and the next call to
    ``/categories/defaults`` seeds again by the same rule that let the first
    call seed. See ``test_seed_defaults_reseeds_after_the_user_empties_the_set``.
    """
    client = _client(_sqlite_engine())
    client.post("/categories/defaults")
    groceries = next(
        c for c in client.get("/categories").json()["categories"] if c["name"] == "Groceries"
    )
    client.delete(f"/categories/{groceries['id']}")

    response = client.post("/categories/defaults")

    names = {c["name"] for c in response.json()["categories"]}
    assert "Groceries" not in names


def test_seed_defaults_reseeds_after_the_user_empties_the_set() -> None:
    client = _client(_sqlite_engine())
    client.post("/categories/defaults")
    for category in client.get("/categories").json()["categories"]:
        client.delete(f"/categories/{category['id']}")
    assert client.get("/categories").json()["categories"] == []

    response = client.post("/categories/defaults")

    # Zero categories is indistinguishable from "never seeded" by the guard's
    # own rule (count == 0), so this reseeds. Documented behaviour, not a bug.
    assert len(response.json()["categories"]) > 0


def test_rename_category() -> None:
    client = _client(_sqlite_engine())
    category_id = client.post("/categories", json={"name": "Groceries"}).json()["id"]

    response = client.post(f"/categories/{category_id}/rename", json={"name": "Food"})

    assert response.status_code == 200
    assert response.json()["name"] == "Food"


def test_rename_unknown_is_404() -> None:
    client = _client(_sqlite_engine())

    response = client.post(f"/categories/{uuid4()}/rename", json={"name": "Food"})

    assert response.status_code == 404


def test_rename_to_existing_name_is_409() -> None:
    client = _client(_sqlite_engine())
    client.post("/categories", json={"name": "Food"})
    category_id = client.post("/categories", json={"name": "Groceries"}).json()["id"]

    response = client.post(f"/categories/{category_id}/rename", json={"name": "Food"})

    assert response.status_code == 409
    assert response.json()["detail"] == "category_name_taken"


def test_rename_to_own_current_name_is_idempotent() -> None:
    client = _client(_sqlite_engine())
    category_id = client.post("/categories", json={"name": "Groceries"}).json()["id"]

    response = client.post(f"/categories/{category_id}/rename", json={"name": "Groceries"})

    assert response.status_code == 200
    assert response.json()["name"] == "Groceries"


def test_delete_category() -> None:
    client = _client(_sqlite_engine())
    category_id = client.post("/categories", json={"name": "Groceries"}).json()["id"]

    assert client.delete(f"/categories/{category_id}").status_code == 204
    assert client.get("/categories").json()["categories"] == []


def test_delete_unknown_is_404() -> None:
    assert _client(_sqlite_engine()).delete(f"/categories/{uuid4()}").status_code == 404


def test_delete_category_confirmed_on_a_transaction_is_refused() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id)
    client = _client(engine)
    category_id = client.post("/categories", json={"name": "Groceries"}).json()["id"]
    client.post(f"/transactions/{tx}/category", json={"category_id": category_id})

    response = client.delete(f"/categories/{category_id}")

    assert response.status_code == 409
    assert response.json()["detail"] == "category_in_use"


def test_delete_category_clears_a_suggestion_and_transaction_survives() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id)
    category_id = _seed_category(engine, user_id=dev_user_id)
    with Session(engine) as session:
        row = session.get(TransactionRow, UUID(tx))
        assert row is not None
        row.suggested_category_id = UUID(category_id)
        session.commit()
    client = _client(engine)

    assert client.delete(f"/categories/{category_id}").status_code == 204

    [surviving] = client.get("/transactions").json()["transactions"]
    assert surviving["id"] == tx
    assert surviving["suggested_category_id"] is None


def test_confirm_category_becomes_effective_over_a_suggestion() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id)
    suggested_id = _seed_category(engine, user_id=dev_user_id, name="Suggested")
    confirmed_id = _seed_category(engine, user_id=dev_user_id, name="Confirmed")
    with Session(engine) as session:
        row = session.get(TransactionRow, UUID(tx))
        assert row is not None
        row.suggested_category_id = UUID(suggested_id)
        session.commit()
    client = _client(engine)

    response = client.post(f"/transactions/{tx}/category", json={"category_id": confirmed_id})
    assert response.status_code == 204

    [projected] = client.get("/transactions").json()["transactions"]
    assert projected["suggested_category_id"] == suggested_id
    assert projected["confirmed_category_id"] == confirmed_id
    assert projected["effective_category_id"] == confirmed_id


def test_clear_confirmed_category_falls_back_to_suggestion() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id)
    suggested_id = _seed_category(engine, user_id=dev_user_id, name="Suggested")
    confirmed_id = _seed_category(engine, user_id=dev_user_id, name="Confirmed")
    with Session(engine) as session:
        row = session.get(TransactionRow, UUID(tx))
        assert row is not None
        row.suggested_category_id = UUID(suggested_id)
        row.confirmed_category_id = UUID(confirmed_id)
        session.commit()
    client = _client(engine)

    response = client.delete(f"/transactions/{tx}/category")
    assert response.status_code == 204

    [projected] = client.get("/transactions").json()["transactions"]
    assert projected["confirmed_category_id"] is None
    assert projected["effective_category_id"] == suggested_id


def test_clear_when_nothing_confirmed_is_idempotent() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id)
    client = _client(engine)

    assert client.delete(f"/transactions/{tx}/category").status_code == 204
    assert client.delete(f"/transactions/{tx}/category").status_code == 204


def test_confirm_unknown_category_is_404() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(f"/transactions/{tx}/category", json={"category_id": str(uuid4())})

    assert response.status_code == 404
    assert response.json()["detail"] == "unknown category"


def test_confirm_unknown_transaction_is_404() -> None:
    engine = _sqlite_engine()
    category_id = _seed_category(engine, user_id=get_settings().dev_user_id)
    client = _client(engine)

    response = client.post(f"/transactions/{uuid4()}/category", json={"category_id": category_id})

    assert response.status_code == 404
    assert response.json()["detail"] == "unknown transaction"


def test_cannot_confirm_another_users_category() -> None:
    stranger_id = uuid4()
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id)
    theirs = _seed_category(engine, user_id=stranger_id)
    client = _client(engine)

    # The stranger's category is invisible to this user: "not found".
    response = client.post(f"/transactions/{tx}/category", json={"category_id": theirs})

    assert response.status_code == 404
    assert response.json()["detail"] == "unknown category"


def test_cannot_categorize_another_users_transaction() -> None:
    stranger_id = uuid4()
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    theirs = _seed_tx(engine, user_id=stranger_id)
    category_id = _seed_category(engine, user_id=dev_user_id)
    client = _client(engine)

    # The stranger's transaction is invisible to this user: "not found".
    response = client.post(f"/transactions/{theirs}/category", json={"category_id": category_id})

    assert response.status_code == 404
    assert response.json()["detail"] == "unknown transaction"
