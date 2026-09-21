"""Tests for the advance endpoints.

The app is built via the factory and its ``get_session`` dependency is overridden
to a shared in-memory SQLite engine, so the endpoints are exercised end to end
(routing, validation, role write, effective_amount threading) without a running
PostgreSQL. Values are synthetic (see ``docs/engineering.md``).
"""

from collections.abc import Iterator
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _sqlite_engine
from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.models import TransactionRow
from traccio.db.session import get_session
from traccio.domain.enums import KeyStrategy, TransactionStatus

_DAY = datetime(2026, 3, 1, tzinfo=UTC)


def _tx(
    *, user_id: UUID, amount: int, stable_key: str, when: datetime | None = _DAY
) -> TransactionRow:
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=uuid4(),
        amount=amount,
        currency="EUR",
        booked_at=when,
        value_date=when,
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


def _seed_tx(engine: Engine, *, user_id: UUID, amount: int = -5000) -> str:
    with Session(engine) as session:
        tx = _tx(user_id=user_id, amount=amount, stable_key="TX-01")
        session.add(tx)
        session.commit()
        return str(tx.id)


def test_create_sets_role_and_zeroes_down_effective_amount() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000)
    client = _client(engine)

    response = client.post(
        "/advances",
        json={
            "transaction_id": tx_id,
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["transaction_id"] == tx_id
    assert body["own_share"] == 1000
    assert body["receivable"] == 4000
    assert body["outstanding"] == 4000  # no reimbursements yet
    assert body["status"] == "open"
    # A stable id and the derived reimbursement state ride along even for a
    # brand-new advance with no reimbursements yet (ADR 0012).
    [participant] = body["participants"]
    assert participant["name"] == "TEST FRIEND 01"
    assert participant["expected_amount"] == 4000
    assert participant["reimbursed"] == 0
    assert participant["outstanding"] == 4000
    assert participant["excess"] == 0
    assert participant["status"] == "outstanding"
    assert UUID(participant["id"])  # stable, non-empty identifier

    # The transaction now counts only the user's share as spending (signed).
    [tx] = client.get("/transactions").json()["transactions"]
    assert tx["role"] == "advance"
    assert tx["amount"] == -5000
    assert tx["effective_amount"] == -1000

    # Listed and fetchable.
    assert len(client.get("/advances").json()["advances"]) == 1
    assert client.get(f"/advances/{body['id']}").status_code == 200


def test_delete_reverts_role_and_full_effective_amount() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000)
    client = _client(engine)

    advance_id = client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000}).json()[
        "id"
    ]

    response = client.delete(f"/advances/{advance_id}")

    assert response.status_code == 204
    [tx] = client.get("/transactions").json()["transactions"]
    assert tx["role"] == "personal"
    assert tx["effective_amount"] == -5000
    assert client.get("/advances").json() == {
        "advances": [],
        "summary": {"by_person": [], "totals": []},
    }
    assert client.get(f"/advances/{advance_id}").status_code == 404


def test_delete_unknown_advance_is_404() -> None:
    assert _client(_sqlite_engine()).delete(f"/advances/{uuid4()}").status_code == 404


def test_create_on_unknown_transaction_is_404() -> None:
    response = _client(_sqlite_engine()).post(
        "/advances", json={"transaction_id": str(uuid4()), "own_share": 1000}
    )
    assert response.status_code == 404


def test_create_twice_on_same_transaction_is_409() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000)
    client = _client(engine)

    payload = {"transaction_id": tx_id, "own_share": 1000}
    assert client.post("/advances", json=payload).status_code == 201
    assert client.post("/advances", json=payload).status_code == 409


def test_create_with_share_over_amount_is_422() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=-5000)

    response = _client(engine).post("/advances", json={"transaction_id": tx_id, "own_share": 6000})
    assert response.status_code == 422
    assert response.json()["detail"] == "share_out_of_range"


def test_create_on_incoming_transaction_is_422() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_tx(engine, user_id=dev_user_id, amount=5000)  # incoming

    response = _client(engine).post("/advances", json={"transaction_id": tx_id, "own_share": 1000})
    assert response.status_code == 422
    assert response.json()["detail"] == "not_outgoing"


def test_create_on_another_users_transaction_is_404() -> None:
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        theirs = _tx(user_id=stranger_id, amount=-5000, stable_key="TX-THEIRS")
        session.add(theirs)
        session.commit()
        theirs_id = str(theirs.id)

    response = _client(engine).post(
        "/advances", json={"transaction_id": theirs_id, "own_share": 1000}
    )
    # The stranger's transaction is invisible to this user: "not found".
    assert response.status_code == 404


def _seed_named_tx(
    engine: Engine,
    *,
    user_id: UUID,
    amount: int,
    stable_key: str,
    when: datetime | None = _DAY,
) -> str:
    with Session(engine) as session:
        tx = _tx(user_id=user_id, amount=amount, stable_key=stable_key, when=when)
        session.add(tx)
        session.commit()
        return str(tx.id)


def test_list_envelope_carries_cross_advance_summary() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_named_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-A")
    client = _client(engine)

    advance_id = client.post(
        "/advances",
        json={
            "transaction_id": tx_id,
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    ).json()["id"]
    participant_id = client.get(f"/advances/{advance_id}").json()["participants"][0]["id"]
    client.post(
        f"/advances/{advance_id}/reimbursements",
        json={"amount": 1500, "participant_id": participant_id},
    )

    summary = client.get("/advances").json()["summary"]
    assert summary["totals"] == [
        {
            "currency": "EUR",
            "outstanding": 2500,
            "expected": 4000,
            "reimbursed": 1500,
            "open_advances": 1,
        }
    ]
    [person] = summary["by_person"]
    assert person == {
        "name": "TEST FRIEND 01",
        "person_key": "test friend 01",
        "currency": "EUR",
        "expected": 4000,
        "reimbursed": 1500,
        "outstanding": 2500,
        "advance_count": 1,
    }


def test_status_filter_narrows_rows_but_not_summary() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    kept = _seed_named_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-OPEN")
    other = _seed_named_tx(engine, user_id=dev_user_id, amount=-9000, stable_key="TX-WOFF")
    client = _client(engine)

    client.post("/advances", json={"transaction_id": kept, "own_share": 1000})
    woff = client.post("/advances", json={"transaction_id": other, "own_share": 2000})
    client.post(f"/advances/{woff.json()['id']}/write-off")

    filtered = client.get("/advances", params={"status": "open"}).json()
    assert [a["transaction_id"] for a in filtered["advances"]] == [kept]
    # The written-off advance's 7000 receivable is deliberately absent from the
    # total (expected and reimbursed alike), but its currency row still
    # reflects only the open advance.
    assert filtered["summary"]["totals"] == [
        {
            "currency": "EUR",
            "outstanding": 4000,
            "expected": 4000,
            "reimbursed": 0,
            "open_advances": 1,
        }
    ]

    unfiltered = client.get("/advances").json()
    assert {a["transaction_id"] for a in unfiltered["advances"]} == {kept, other}
    assert unfiltered["summary"]["totals"] == filtered["summary"]["totals"]


def test_summary_rolls_one_person_across_two_advances() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    first = _seed_named_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-1")
    second = _seed_named_tx(engine, user_id=dev_user_id, amount=-3000, stable_key="TX-2")
    client = _client(engine)

    for tx_id, share, expected in ((first, 1000, 4000), (second, 500, 2500)):
        client.post(
            "/advances",
            json={
                "transaction_id": tx_id,
                "own_share": share,
                "participants": [{"name": "  marco  ", "expected_amount": expected}],
            },
        )

    [person] = client.get("/advances").json()["summary"]["by_person"]
    assert person["name"] == "marco"  # whitespace collapsed, first spelling
    assert person["expected"] == 6500
    assert person["outstanding"] == 6500
    assert person["advance_count"] == 2


def test_summary_is_scoped_to_the_caller() -> None:
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    mine = _seed_named_tx(engine, user_id=dev_user_id, amount=-5000, stable_key="TX-MINE")
    _seed_named_tx(engine, user_id=stranger_id, amount=-8000, stable_key="TX-THEIRS")
    client = _client(engine)

    client.post(
        "/advances",
        json={
            "transaction_id": mine,
            "own_share": 1000,
            "participants": [{"name": "TEST FRIEND 01", "expected_amount": 4000}],
        },
    )

    summary = client.get("/advances").json()["summary"]
    assert summary["totals"] == [
        {
            "currency": "EUR",
            "outstanding": 4000,
            "expected": 4000,
            "reimbursed": 0,
            "open_advances": 1,
        }
    ]
    assert [p["name"] for p in summary["by_person"]] == ["TEST FRIEND 01"]


def test_tracking_start_floor_hides_pre_cutoff_advances_from_rows_and_summary() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    old_tx = _seed_named_tx(
        engine,
        user_id=dev_user_id,
        amount=-5000,
        stable_key="TX-OLD",
        when=datetime(2026, 1, 10, tzinfo=UTC),
    )
    new_tx = _seed_named_tx(
        engine,
        user_id=dev_user_id,
        amount=-3000,
        stable_key="TX-NEW",
        when=datetime(2026, 8, 10, tzinfo=UTC),
    )
    client = _client(engine)
    for tx_id, share in ((old_tx, 1000), (new_tx, 500)):
        client.post(
            "/advances",
            json={
                "transaction_id": tx_id,
                "own_share": share,
                "participants": [{"name": "TEST FRIEND 01", "expected_amount": share + 500}],
            },
        )

    # No floor: both advances count.
    unfiltered = client.get("/advances").json()
    assert {a["transaction_id"] for a in unfiltered["advances"]} == {old_tx, new_tx}
    assert unfiltered["summary"]["totals"] == [
        {
            "currency": "EUR",
            "outstanding": 6500,
            "expected": 6500,
            "reimbursed": 0,
            "open_advances": 2,
        }
    ]

    # Floor after the old movement: only the new advance is left, rows and
    # summary in lockstep.
    assert client.post("/settings", json={"tracking_start_date": "2026-07-01"}).status_code == 200
    floored = client.get("/advances").json()
    assert [a["transaction_id"] for a in floored["advances"]] == [new_tx]
    assert floored["summary"]["totals"] == [
        {
            "currency": "EUR",
            "outstanding": 2500,
            "expected": 2500,
            "reimbursed": 0,
            "open_advances": 1,
        }
    ]
    assert [p["name"] for p in floored["summary"]["by_person"]] == ["TEST FRIEND 01"]
    assert floored["summary"]["by_person"][0]["advance_count"] == 1

    # The floored-out advance is still reachable by id (ADR 0024 §5).
    old_advance_id = next(a["id"] for a in unfiltered["advances"] if a["transaction_id"] == old_tx)
    assert client.get(f"/advances/{old_advance_id}").status_code == 200


def test_tracking_start_none_leaves_every_advance_visible() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_named_tx(
        engine,
        user_id=dev_user_id,
        amount=-5000,
        stable_key="TX-OLD",
        when=datetime(2020, 1, 1, tzinfo=UTC),
    )
    client = _client(engine)
    client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000})

    body = client.get("/advances").json()
    assert [a["transaction_id"] for a in body["advances"]] == [tx_id]
    assert body["summary"]["totals"] == [
        {
            "currency": "EUR",
            "outstanding": 4000,
            "expected": 4000,
            "reimbursed": 0,
            "open_advances": 1,
        }
    ]


def test_advance_response_carries_transaction_description_and_date() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_named_tx(
        engine,
        user_id=dev_user_id,
        amount=-5000,
        stable_key="TX-DESC",
        when=datetime(2026, 8, 4, 9, 30, tzinfo=UTC),
    )
    client = _client(engine)
    client.post(
        "/advances",
        json={
            "transaction_id": tx_id,
            "own_share": 1000,
            "participants": [{"name": "  Marco Rossi  ", "expected_amount": 4000}],
        },
    )

    [advance] = client.get("/advances").json()["advances"]
    # The list row can show what the advance was for without a per-id fetch.
    assert advance["description"] == "TEST MERCHANT 01"
    assert advance["display_description"] is None
    assert advance["booked_at"].startswith("2026-08-04")
    # The participant carries the same grouping key as its summary row.
    [participant] = advance["participants"]
    assert participant["person_key"] == "marco rossi"
    [person] = client.get("/advances").json()["summary"]["by_person"]
    assert person["person_key"] == participant["person_key"]
    assert person["name"] == "Marco Rossi"  # whitespace collapsed, case kept


def test_a_dateless_advance_transaction_is_hidden_once_a_floor_is_set() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    tx_id = _seed_named_tx(
        engine, user_id=dev_user_id, amount=-5000, stable_key="TX-DATELESS", when=None
    )
    client = _client(engine)
    client.post("/advances", json={"transaction_id": tx_id, "own_share": 1000})

    assert len(client.get("/advances").json()["advances"]) == 1
    client.post("/settings", json={"tracking_start_date": "2026-07-01"})
    floored = client.get("/advances").json()
    assert floored["advances"] == []
    assert floored["summary"]["totals"] == []
