"""Tests for the reimbursement and write-off endpoints.

The app is built via the factory and its ``get_session`` dependency is overridden
to a shared in-memory SQLite engine, so the endpoints are exercised end to end
(routing, validation, role writes, effective_amount threading, derived status)
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
from traccio.db.models import TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, TransactionStatus

_DAY = datetime(2026, 3, 1, tzinfo=UTC)


def _tx(*, user_id: UUID, amount: int, stable_key: str) -> TransactionRow:
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=uuid4(),
        amount=amount,
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


def _seed_tx(engine: Engine, *, user_id: UUID, amount: int, stable_key: str) -> str:
    with Session(engine) as session:
        tx = _tx(user_id=user_id, amount=amount, stable_key=stable_key)
        session.add(tx)
        session.commit()
        return str(tx.id)


def _effective_amount(client: TestClient, tx_id: str) -> int:
    transactions = client.get("/transactions").json()["transactions"]
    [tx] = [t for t in transactions if t["id"] == tx_id]
    return int(tx["effective_amount"])


def test_cash_reimbursement_reduces_outstanding_then_settles() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    advance_id = client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000}).json()[
        "id"
    ]

    # Partial cash reimbursement: outstanding drops, still open.
    partial = client.post(
        f"/advances/{advance_id}/reimbursements", json={"amount": 1500, "note": "cash, dinner"}
    )
    assert partial.status_code == 201
    body = client.get(f"/advances/{advance_id}").json()
    assert body["reimbursed"] == 1500
    assert body["outstanding"] == 2500
    assert body["excess"] == 0
    assert body["status"] == "open"

    # Reimbursing the rest settles it; the own share is still the only spending.
    client.post(f"/advances/{advance_id}/reimbursements", json={"amount": 2500})
    body = client.get(f"/advances/{advance_id}").json()
    assert body["reimbursed"] == 4000
    assert body["outstanding"] == 0
    assert body["status"] == "settled"
    assert _effective_amount(client, tx_id) == -1000


def test_over_reimbursement_is_flagged_not_absorbed() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    advance_id = client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000}).json()[
        "id"
    ]

    client.post(f"/advances/{advance_id}/reimbursements", json={"amount": 4500})
    body = client.get(f"/advances/{advance_id}").json()
    assert body["outstanding"] == 0
    assert body["excess"] == 500
    assert body["status"] == "settled"


def test_linking_incoming_transaction_zeroes_its_effective_amount() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-OUT")
    in_id = _seed_tx(engine, user_id=dev_user_id, amount=3000, stable_key="TX-IN")
    client = _client(engine)

    advance_id = client.post(
        "/advances", json={"transaction_id": out_id, "own_share": 1000}
    ).json()["id"]

    response = client.post(
        f"/advances/{advance_id}/reimbursements", json={"amount": 3000, "transaction_id": in_id}
    )
    assert response.status_code == 201
    assert response.json()["transaction_id"] == in_id

    # The linked incoming transaction now counts as neither income nor spending.
    assert _effective_amount(client, in_id) == 0
    body = client.get(f"/advances/{advance_id}").json()
    assert body["reimbursed"] == 3000
    assert body["outstanding"] == 1000

    # Listing reimbursements shows the one linked entry.
    listed = client.get(f"/advances/{advance_id}/reimbursements").json()["reimbursements"]
    assert [r["transaction_id"] for r in listed] == [in_id]


def test_deleting_linked_reimbursement_restores_transaction_and_reopens() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-OUT")
    in_id = _seed_tx(engine, user_id=dev_user_id, amount=4000, stable_key="TX-IN")
    client = _client(engine)

    advance_id = client.post(
        "/advances", json={"transaction_id": out_id, "own_share": 1000}
    ).json()["id"]
    reimbursement_id = client.post(
        f"/advances/{advance_id}/reimbursements", json={"amount": 4000, "transaction_id": in_id}
    ).json()["id"]

    # Fully reimbursed → settled.
    assert client.get(f"/advances/{advance_id}").json()["status"] == "settled"

    response = client.delete(f"/advances/{advance_id}/reimbursements/{reimbursement_id}")
    assert response.status_code == 204

    # The incoming transaction is personal again (its full amount counts).
    assert _effective_amount(client, in_id) == 4000
    body = client.get(f"/advances/{advance_id}").json()
    assert body["reimbursed"] == 0
    assert body["outstanding"] == 4000
    assert body["status"] == "open"


def test_write_off_moves_outstanding_into_spending_and_reopen_reverts() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    advance_id = client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000}).json()[
        "id"
    ]
    client.post(f"/advances/{advance_id}/reimbursements", json={"amount": 1500})

    written = client.post(f"/advances/{advance_id}/write-off")
    assert written.status_code == 200
    assert written.json()["status"] == "written_off"
    # Spending = own_share (1000) + outstanding (2500).
    assert _effective_amount(client, tx_id) == -3500

    reopened = client.post(f"/advances/{advance_id}/reopen")
    assert reopened.status_code == 200
    assert reopened.json()["status"] == "open"
    assert _effective_amount(client, tx_id) == -1000


def test_write_off_with_nothing_outstanding_is_422() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    advance_id = client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000}).json()[
        "id"
    ]
    client.post(f"/advances/{advance_id}/reimbursements", json={"amount": 4000})  # fully settled

    response = client.post(f"/advances/{advance_id}/write-off")
    assert response.status_code == 422
    assert response.json()["detail"] == "nothing_outstanding"


def test_reimbursing_a_written_off_advance_is_422() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    advance_id = client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000}).json()[
        "id"
    ]
    client.post(f"/advances/{advance_id}/write-off")

    response = client.post(f"/advances/{advance_id}/reimbursements", json={"amount": 1000})
    assert response.status_code == 422
    assert response.json()["detail"] == "advance_written_off"


def test_linking_outgoing_transaction_is_422() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-OUT")
    other_out_id = _seed_tx(engine, user_id=dev_user_id, amount=-2000, stable_key="TX-OUT2")
    client = _client(engine)

    advance_id = client.post(
        "/advances", json={"transaction_id": out_id, "own_share": 1000}
    ).json()["id"]

    response = client.post(
        f"/advances/{advance_id}/reimbursements",
        json={"amount": 2000, "transaction_id": other_out_id},
    )
    assert response.status_code == 422
    assert response.json()["detail"] == "not_incoming"


def test_reimbursement_on_another_users_advance_is_404() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        theirs = _tx(user_id=stranger_id, amount=-5000, stable_key="TX-THEIRS")
        session.add(theirs)
        session.commit()
    client = _client(engine)

    # An advance the current user does not own is invisible: "not found".
    response = client.post(f"/advances/{uuid4()}/reimbursements", json={"amount": 1000})
    assert response.status_code == 404


# --- participant attribution (ADR 0012) --------------------------------------


def test_reimbursement_attributed_to_a_participant_settles_only_them() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-9000, stable_key="TX-01")
    client = _client(engine)

    created = client.post(
        "/advances",
        json={
            "transaction_id": tx_id,
            "own_share": 1000,
            "participants": [
                {"name": "TEST FRIEND 01", "expected_amount": 4000},
                {"name": "TEST FRIEND 02", "expected_amount": 4000},
            ],
        },
    ).json()
    advance_id = created["id"]
    friend_one_id, friend_two_id = (p["id"] for p in created["participants"])

    response = client.post(
        f"/advances/{advance_id}/reimbursements",
        json={"amount": 4000, "participant_id": friend_one_id},
    )
    assert response.status_code == 201
    assert response.json()["participant_id"] == friend_one_id

    body = client.get(f"/advances/{advance_id}").json()
    # The advance-level total is unaffected by attribution — same aggregate
    # math as an unattributed reimbursement.
    assert body["reimbursed"] == 4000
    by_id = {p["id"]: p for p in body["participants"]}
    assert by_id[friend_one_id]["status"] == "settled"
    assert by_id[friend_one_id]["reimbursed"] == 4000
    assert by_id[friend_two_id]["status"] == "outstanding"
    assert by_id[friend_two_id]["reimbursed"] == 0

    # The list endpoint must show the exact same per-participant states —
    # it derives them from a separate aggregate query (never one per advance).
    [listed] = client.get("/advances").json()["advances"]
    listed_by_id = {p["id"]: p for p in listed["participants"]}
    assert listed_by_id[friend_one_id]["status"] == "settled"
    assert listed_by_id[friend_two_id]["status"] == "outstanding"


def test_reimbursement_with_unknown_participant_id_is_404() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    advance_id = client.post(
        "/advances",
        json={
            "transaction_id": tx_id,
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    ).json()["id"]

    response = client.post(
        f"/advances/{advance_id}/reimbursements",
        json={"amount": 1000, "participant_id": str(uuid4())},
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "unknown_participant"


def test_reimbursement_with_a_participant_from_another_advance_is_404() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_a = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    tx_b = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-B")
    client = _client(engine)

    advance_a = client.post(
        "/advances",
        json={
            "transaction_id": tx_a,
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    ).json()
    advance_b_id = client.post(
        "/advances", json={"transaction_id": tx_b, "own_share": 1000}
    ).json()["id"]
    other_advances_participant_id = advance_a["participants"][0]["id"]

    response = client.post(
        f"/advances/{advance_b_id}/reimbursements",
        json={"amount": 1000, "participant_id": other_advances_participant_id},
    )
    assert response.status_code == 404
    assert response.json()["detail"] == "unknown_participant"


def test_reimbursement_without_participant_id_stays_unattributed() -> None:
    """Retro-compatibility: omitting participant_id behaves exactly as before
    ADR 0012 — every participant simply stays outstanding."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    advance_id = client.post(
        "/advances",
        json={
            "transaction_id": tx_id,
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    ).json()["id"]

    response = client.post(f"/advances/{advance_id}/reimbursements", json={"amount": 1000})
    assert response.status_code == 201
    assert response.json()["participant_id"] is None

    [participant] = client.get(f"/advances/{advance_id}").json()["participants"]
    assert participant["status"] == "outstanding"
    assert participant["reimbursed"] == 0


def test_participant_id_round_trips_stably_across_create_and_read() -> None:
    """A participant's id must be stable between the create response and every
    later read — it did not exist at all before ADR 0012 gave Participant a
    real identity."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-01")
    client = _client(engine)

    created = client.post(
        "/advances",
        json={
            "transaction_id": tx_id,
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    ).json()
    [created_participant] = created["participants"]
    UUID(created_participant["id"])  # a real UUID, not an empty/placeholder value

    fetched = client.get(f"/advances/{created['id']}").json()
    [fetched_participant] = fetched["participants"]
    assert fetched_participant["id"] == created_participant["id"]

    [listed] = client.get("/advances").json()["advances"]
    [listed_participant] = listed["participants"]
    assert listed_participant["id"] == created_participant["id"]
