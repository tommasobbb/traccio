"""Tests for the event endpoints.

The app is built via the factory and its ``get_session`` dependency is overridden
to a shared in-memory SQLite engine, so the endpoints are exercised end to end
(routing, membership writes, the derived net total) without a running
PostgreSQL. Values are synthetic (see ``.claude/rules/data-safety.md``).
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
from traccio.db.models import TransactionRow
from traccio.db.repositories import create_event
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, TransactionRole, TransactionStatus
from traccio.domain.models import Event

_DAY = datetime(2026, 3, 1, tzinfo=UTC)


def _tx(
    *,
    user_id: UUID,
    amount: int,
    stable_key: str,
    role: TransactionRole = TransactionRole.PERSONAL,
    currency: str = "EUR",
) -> TransactionRow:
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=uuid4(),
        amount=amount,
        currency=currency,
        booked_at=_DAY,
        value_date=_DAY,
        description="TEST MERCHANT 01",
        display_description=None,
        status=TransactionStatus.BOOKED,
        role=role,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


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
    amount: int,
    stable_key: str,
    role: TransactionRole = TransactionRole.PERSONAL,
    currency: str = "EUR",
) -> str:
    with Session(engine) as session:
        tx = _tx(
            user_id=user_id, amount=amount, stable_key=stable_key, role=role, currency=currency
        )
        session.add(tx)
        session.commit()
        return str(tx.id)


def test_create_event_starts_empty() -> None:
    client = _client(_sqlite_engine())

    response = client.post("/events", json={"name": "TEST TRIP 01"})

    assert response.status_code == 201
    body = response.json()
    assert body["name"] == "TEST TRIP 01"
    assert body["status"] == "active"
    assert body["member_count"] == 0
    assert body["total"] == 0
    assert body["currency"] is None


def test_create_event_with_emoji_and_color_round_trips() -> None:
    client = _client(_sqlite_engine())

    response = client.post(
        "/events", json={"name": "TEST TRIP 01", "emoji": "🇹🇷", "color": "teal"}
    )

    assert response.status_code == 201
    body = response.json()
    assert body["emoji"] == "🇹🇷"
    assert body["color"] == "teal"
    # And it survives a fresh read.
    assert client.get(f"/events/{body['id']}").json()["emoji"] == "🇹🇷"


def test_create_event_rejects_a_non_emoji() -> None:
    client = _client(_sqlite_engine())

    response = client.post("/events", json={"name": "TEST TRIP 01", "emoji": "trip"})

    assert response.status_code == 422


def test_update_event_replaces_name_emoji_color_and_dates() -> None:
    client = _client(_sqlite_engine())
    event_id = client.post(
        "/events", json={"name": "TEST TRIP 01", "emoji": "🎉", "color": "blue"}
    ).json()["id"]

    response = client.post(
        f"/events/{event_id}",
        json={
            "name": "TEST TRIP 02",
            "emoji": "🏠",
            "color": None,
            "start_date": "2026-05-03",
            "end_date": "2026-05-17",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["name"] == "TEST TRIP 02"
    assert body["emoji"] == "🏠"
    assert body["color"] is None  # explicit null clears it
    assert body["start_date"] == "2026-05-03"
    assert body["status"] == "active"  # untouched


def test_update_event_rejects_a_non_emoji() -> None:
    client = _client(_sqlite_engine())
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]

    response = client.post(
        f"/events/{event_id}", json={"name": "TEST TRIP 01", "emoji": "🎉🎂"}
    )

    assert response.status_code == 422


def test_update_unknown_event_is_404() -> None:
    client = _client(_sqlite_engine())

    response = client.post(
        f"/events/{uuid4()}", json={"name": "TEST TRIP 01"}
    )

    assert response.status_code == 404


def test_update_another_users_event_is_404() -> None:
    engine = _sqlite_engine()
    stranger_id = uuid4()
    with Session(engine) as session:
        created = create_event(session, event=Event(user_id=stranger_id, name="TEST TRIP 01"))
        session.commit()
        their_event_id = str(created.id)

    response = _client(engine).post(
        f"/events/{their_event_id}", json={"name": "HIJACKED"}
    )
    assert response.status_code == 404


def test_assign_transactions_and_derive_total() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_a = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    tx_b = _seed_tx(engine, user_id=dev_user_id, amount=-2500, stable_key="TX-B")
    client = _client(engine)

    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]
    assert (
        client.post(f"/events/{event_id}/transactions", json={"transaction_id": tx_a}).status_code
        == 204
    )
    assert (
        client.post(f"/events/{event_id}/transactions", json={"transaction_id": tx_b}).status_code
        == 204
    )

    body = client.get(f"/events/{event_id}").json()
    assert body["member_count"] == 2
    assert body["total"] == -7500
    assert body["currency"] == "EUR"


def test_total_zeroes_transfer_and_applies_advance_share() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    personal = _seed_tx(engine, user_id=dev_user_id, amount=-3000, stable_key="TX-P")
    transfer = _seed_tx(
        engine, user_id=dev_user_id, amount=-10000, stable_key="TX-T", role=TransactionRole.TRANSFER
    )
    advanced = _seed_tx(engine, user_id=dev_user_id, amount=-100000, stable_key="TX-ADV")
    client = _client(engine)

    # Turn the advanced transaction into an advance: only €200 of the €1000 is ours.
    assert (
        client.post("/advances", json={"transaction_id": advanced, "own_share": 20000}).status_code
        == 201
    )

    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]
    for tx_id in (personal, transfer, advanced):
        assert (
            client.post(
                f"/events/{event_id}/transactions", json={"transaction_id": tx_id}
            ).status_code
            == 204
        )

    body = client.get(f"/events/{event_id}").json()
    # -3000 (personal) + 0 (transfer) + -20000 (advance own share) = -23000.
    assert body["member_count"] == 3
    assert body["total"] == -23000
    assert body["currency"] == "EUR"


def test_transaction_belongs_to_at_most_one_event() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    client = _client(engine)

    first = client.post("/events", json={"name": "FIRST"}).json()["id"]
    second = client.post("/events", json={"name": "SECOND"}).json()["id"]

    assert (
        client.post(f"/events/{first}/transactions", json={"transaction_id": tx}).status_code == 204
    )
    # Re-assigning to the same event is idempotent.
    assert (
        client.post(f"/events/{first}/transactions", json={"transaction_id": tx}).status_code == 204
    )
    # Assigning to a different event is refused.
    assert (
        client.post(f"/events/{second}/transactions", json={"transaction_id": tx}).status_code
        == 409
    )


def test_assign_unknown_transaction_or_event_is_404() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    client = _client(engine)
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]

    assert (
        client.post(
            f"/events/{event_id}/transactions", json={"transaction_id": str(uuid4())}
        ).status_code
        == 404
    )
    assert (
        client.post(f"/events/{uuid4()}/transactions", json={"transaction_id": tx}).status_code
        == 404
    )


def test_delete_event_keeps_transactions() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    client = _client(engine)
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]
    client.post(f"/events/{event_id}/transactions", json={"transaction_id": tx})

    assert client.delete(f"/events/{event_id}").status_code == 204
    assert client.get(f"/events/{event_id}").status_code == 404
    # The transaction survives, untouched.
    [surviving] = client.get("/transactions").json()["transactions"]
    assert surviving["id"] == tx
    assert surviving["role"] == "personal"
    assert surviving["effective_amount"] == -5000


def test_unassign_transaction() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    client = _client(engine)
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]
    client.post(f"/events/{event_id}/transactions", json={"transaction_id": tx})

    assert client.delete(f"/events/{event_id}/transactions/{tx}").status_code == 204
    assert client.get(f"/events/{event_id}").json()["member_count"] == 0
    # Unassigning a non-member is a 404.
    assert client.delete(f"/events/{event_id}/transactions/{tx}").status_code == 404


def test_close_and_reopen_event() -> None:
    client = _client(_sqlite_engine())
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]

    assert client.post(f"/events/{event_id}/close").json()["status"] == "closed"
    assert client.post(f"/events/{event_id}/reopen").json()["status"] == "active"


def test_mixed_currency_assignment_is_refused() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    eur = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-EUR")
    usd = _seed_tx(engine, user_id=dev_user_id, amount=-4000, stable_key="TX-USD", currency="USD")
    client = _client(engine)
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]

    assert (
        client.post(f"/events/{event_id}/transactions", json={"transaction_id": eur}).status_code
        == 204
    )
    # A second member in a different currency has no single total: refused.
    response = client.post(f"/events/{event_id}/transactions", json={"transaction_id": usd})
    assert response.status_code == 422
    assert response.json()["detail"] == "mixed_currency"


def test_delete_unknown_event_is_404() -> None:
    assert _client(_sqlite_engine()).delete(f"/events/{uuid4()}").status_code == 404


def test_event_transactions_lists_members_most_recent_first() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    older = _seed_tx(engine, user_id=dev_user_id, amount=-1000, stable_key="TX-OLDER")
    newer = _seed_tx(engine, user_id=dev_user_id, amount=-2000, stable_key="TX-NEWER")
    # Give the two rows distinct booked_at dates so ordering is unambiguous.
    with Session(engine) as session:
        session.get(TransactionRow, UUID(older)).booked_at = datetime(2026, 3, 1, tzinfo=UTC)
        session.get(TransactionRow, UUID(newer)).booked_at = datetime(2026, 3, 5, tzinfo=UTC)
        session.commit()
    client = _client(engine)
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]
    client.post(f"/events/{event_id}/transactions", json={"transaction_id": older})
    client.post(f"/events/{event_id}/transactions", json={"transaction_id": newer})

    response = client.get(f"/events/{event_id}/transactions")

    assert response.status_code == 200
    ids = [tx["id"] for tx in response.json()["transactions"]]
    assert ids == [newer, older]


def test_event_transactions_empty_event_returns_empty_list() -> None:
    client = _client(_sqlite_engine())
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]

    response = client.get(f"/events/{event_id}/transactions")

    assert response.status_code == 200
    assert response.json()["transactions"] == []


def test_event_transactions_unknown_event_is_404() -> None:
    assert _client(_sqlite_engine()).get(f"/events/{uuid4()}/transactions").status_code == 404


def test_event_transactions_another_users_event_is_404() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        theirs = create_event(session, event=Event(user_id=stranger_id, name="THEIRS"))
        session.commit()
        event_id = theirs.id
    client = _client(engine)

    assert client.get(f"/events/{event_id}/transactions").status_code == 404


def test_event_transactions_exposes_advance_share_not_full_amount() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    advanced = _seed_tx(engine, user_id=dev_user_id, amount=-100000, stable_key="TX-ADV")
    client = _client(engine)
    client.post("/advances", json={"transaction_id": advanced, "own_share": 20000})
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]
    client.post(f"/events/{event_id}/transactions", json={"transaction_id": advanced})

    [member] = client.get(f"/events/{event_id}/transactions").json()["transactions"]

    assert member["amount"] == -100000
    assert member["effective_amount"] == -20000


def test_event_summary_breaks_spending_down_by_category() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_a = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    tx_b = _seed_tx(engine, user_id=dev_user_id, amount=-2500, stable_key="TX-B")
    income_tx = _seed_tx(engine, user_id=dev_user_id, amount=1000, stable_key="TX-INC")
    client = _client(engine)

    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]
    for tx in (tx_a, tx_b, income_tx):
        client.post(f"/events/{event_id}/transactions", json={"transaction_id": tx})

    summary = client.get(f"/events/{event_id}/summary").json()
    assert summary["spending"] == 7500
    assert summary["income"] == 1000
    assert summary["net"] == -6500  # matches EventResponse.total
    assert summary["currency"] == "EUR"
    # Every member is uncategorized, so one "no category" root holds it all.
    [group] = summary["by_category"]
    assert group["category_id"] is None
    assert group["spending"] == 7500
    assert group["income"] == 1000


def test_event_summary_of_an_empty_event_is_all_zeros() -> None:
    client = _client(_sqlite_engine())
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]

    summary = client.get(f"/events/{event_id}/summary").json()
    assert summary == {"spending": 0, "income": 0, "net": 0, "currency": None, "by_category": []}


def test_event_summary_of_an_unknown_event_is_404() -> None:
    client = _client(_sqlite_engine())
    assert client.get(f"/events/{uuid4()}/summary").status_code == 404


def _seed_tx_dated(engine: Engine, *, user_id: UUID, stable_key: str, when: datetime) -> str:
    with Session(engine) as session:
        tx = _tx(user_id=user_id, amount=-3000, stable_key=stable_key)
        tx.booked_at = when
        tx.value_date = when
        session.add(tx)
        session.commit()
        return str(tx.id)


def test_event_suggestions_returns_ungrouped_transactions_in_the_date_range() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    inside = _seed_tx_dated(
        engine, user_id=dev_user_id, stable_key="TX-IN", when=datetime(2026, 5, 10, tzinfo=UTC)
    )
    _seed_tx_dated(
        engine, user_id=dev_user_id, stable_key="TX-OUT", when=datetime(2026, 3, 1, tzinfo=UTC)
    )
    already = _seed_tx_dated(
        engine, user_id=dev_user_id, stable_key="TX-MEMBER", when=datetime(2026, 5, 12, tzinfo=UTC)
    )
    client = _client(engine)
    event_id = client.post(
        "/events",
        json={"name": "TEST TRIP 01", "start_date": "2026-05-01", "end_date": "2026-05-31"},
    ).json()["id"]
    client.post(f"/events/{event_id}/transactions", json={"transaction_id": already})

    suggested = client.get(f"/events/{event_id}/suggestions").json()["transactions"]
    ids = {t["id"] for t in suggested}
    assert ids == {inside}  # in range, and not already grouped


def test_event_suggestions_is_empty_without_a_full_date_range() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    _seed_tx_dated(
        engine, user_id=dev_user_id, stable_key="TX-IN", when=datetime(2026, 5, 10, tzinfo=UTC)
    )
    client = _client(engine)
    only_start = client.post(
        "/events", json={"name": "TEST TRIP 01", "start_date": "2026-05-01"}
    ).json()["id"]

    assert client.get(f"/events/{only_start}/suggestions").json() == {"transactions": []}


def test_event_suggestions_of_an_unknown_event_is_404() -> None:
    client = _client(_sqlite_engine())
    assert client.get(f"/events/{uuid4()}/suggestions").status_code == 404


def test_cannot_assign_another_users_transaction() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    theirs = _seed_tx(engine, user_id=stranger_id, amount=-5000, stable_key="TX-THEIRS")
    client = _client(engine)
    event_id = client.post("/events", json={"name": "TEST TRIP 01"}).json()["id"]

    # The stranger's transaction is invisible to this user: "not found".
    assert (
        client.post(f"/events/{event_id}/transactions", json={"transaction_id": theirs}).status_code
        == 404
    )
