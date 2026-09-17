"""Tests for ``GET /transfers/suggestions``.

The app is built via the factory and its ``get_session`` dependency is overridden
to a shared in-memory SQLite engine, so the endpoint is exercised end to end
(routing, detection, response schema) without a running PostgreSQL. Values are
synthetic (see ``.claude/rules/data-safety.md``).
"""

from collections.abc import Iterator
from datetime import UTC, date, datetime
from uuid import UUID, uuid4

from fastapi.testclient import TestClient
from sqlalchemy import Engine
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _sqlite_engine
from traccio.api.main import create_app
from traccio.core.config import get_settings
from traccio.db.models import AccountRow, TransactionRow
from traccio.db.repositories import set_tracking_start_date
from traccio.db.session import get_session
from traccio.domain.enums import AccountKind, KeyStrategy, TransactionStatus

_DAY = datetime(2026, 3, 1, tzinfo=UTC)


def _tx(
    *,
    user_id: UUID,
    account_id: UUID,
    amount: int,
    stable_key: str,
) -> TransactionRow:
    """Build a synthetic booked transaction row."""
    return TransactionRow(
        id=uuid4(),
        user_id=user_id,
        account_id=account_id,
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


def test_suggests_a_matching_pair_for_the_current_user() -> None:
    dev_user_id = get_settings().dev_user_id
    account_a, account_b = uuid4(), uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        out = _tx(user_id=dev_user_id, account_id=account_a, amount=-50000, stable_key="TX-OUT")
        inc = _tx(user_id=dev_user_id, account_id=account_b, amount=50000, stable_key="TX-IN")
        session.add_all([out, inc])
        session.commit()
        out_id, in_id = str(out.id), str(inc.id)

    response = _client(engine).get("/transfers/suggestions")

    assert response.status_code == 200
    [suggestion] = response.json()["suggestions"]
    assert suggestion["outgoing_transaction_id"] == out_id
    assert suggestion["incoming_transaction_id"] == in_id
    assert suggestion["currency"] == "EUR"
    assert suggestion["amount_delta"] == 0
    # Both legs are embedded, the same projection GET /transactions returns,
    # so the client needs no follow-up request per leg.
    assert suggestion["outgoing"]["id"] == out_id
    assert suggestion["outgoing"]["amount"] == -50000
    assert suggestion["incoming"]["id"] == in_id
    assert suggestion["incoming"]["amount"] == 50000
    assert suggestion["incoming"]["description"] == "TEST MERCHANT 01"


def test_never_pairs_across_users() -> None:
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        # The user's outgoing leg and a stranger's incoming leg must not pair —
        # the query is scoped to the user, so the stranger's row is never seen.
        session.add_all(
            [
                _tx(user_id=dev_user_id, account_id=uuid4(), amount=-50000, stable_key="TX-MINE"),
                _tx(user_id=stranger_id, account_id=uuid4(), amount=50000, stable_key="TX-THEIRS"),
            ]
        )
        session.commit()

    response = _client(engine).get("/transfers/suggestions")

    assert response.status_code == 200
    assert response.json() == {"suggestions": []}


def test_empty_when_user_has_no_transactions() -> None:
    response = _client(_sqlite_engine()).get("/transfers/suggestions")

    assert response.status_code == 200
    assert response.json() == {"suggestions": []}


def test_suggestions_start_from_the_tracking_start_floor() -> None:
    """A pair dated entirely before the user's ``tracking_start_date`` is not
    suggested (ADR 0024/0025); a pair after the floor still is."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    old_day = datetime(2025, 1, 1, tzinfo=UTC)
    with Session(engine) as session:
        old_out = _tx(user_id=dev_user_id, account_id=uuid4(), amount=-50000, stable_key="OLD-OUT")
        old_inc = _tx(user_id=dev_user_id, account_id=uuid4(), amount=50000, stable_key="OLD-IN")
        for row in (old_out, old_inc):
            row.booked_at = old_day
            row.value_date = old_day
        new_out = _tx(user_id=dev_user_id, account_id=uuid4(), amount=-25000, stable_key="NEW-OUT")
        new_inc = _tx(user_id=dev_user_id, account_id=uuid4(), amount=25000, stable_key="NEW-IN")
        session.add_all([old_out, old_inc, new_out, new_inc])
        set_tracking_start_date(session, user_id=dev_user_id, value=date(2026, 1, 1))
        session.commit()
        new_ids = {str(new_out.id), str(new_inc.id)}

    suggestions = _client(engine).get("/transfers/suggestions").json()["suggestions"]

    assert len(suggestions) == 1
    assert {
        suggestions[0]["outgoing_transaction_id"],
        suggestions[0]["incoming_transaction_id"],
    } == new_ids


def _seed_pair(engine: Engine, *, user_id: UUID) -> tuple[str, str]:
    """Seed a clean opposite-sign pair and return (outgoing_id, incoming_id)."""
    with Session(engine) as session:
        out = _tx(user_id=user_id, account_id=uuid4(), amount=-50000, stable_key="TX-OUT")
        inc = _tx(user_id=user_id, account_id=uuid4(), amount=50000, stable_key="TX-IN")
        session.add_all([out, inc])
        session.commit()
        return str(out.id), str(inc.id)


def test_confirm_links_pair_and_zeroes_effective_amount() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, in_id = _seed_pair(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["outgoing_transaction_id"] == out_id
    assert body["incoming_transaction_id"] == in_id

    # Both legs now carry role=transfer, so their effective_amount is zero,
    # derived by the one pure domain function on GET /transactions.
    by_id = {t["id"]: t for t in client.get("/transactions").json()["transactions"]}
    assert by_id[out_id]["role"] == "transfer"
    assert by_id[in_id]["role"] == "transfer"
    assert by_id[out_id]["effective_amount"] == 0
    assert by_id[in_id]["effective_amount"] == 0

    # The confirmed pair no longer appears as a suggestion and is listed.
    assert client.get("/transfers/suggestions").json() == {"suggestions": []}
    assert len(client.get("/transfers").json()["transfers"]) == 1


def test_delete_reverts_roles_and_reinstates_the_suggestion() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, in_id = _seed_pair(engine, user_id=dev_user_id)
    client = _client(engine)

    transfer_id = client.post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    ).json()["id"]

    response = client.delete(f"/transfers/{transfer_id}")

    assert response.status_code == 204
    by_id = {t["id"]: t for t in client.get("/transactions").json()["transactions"]}
    assert by_id[out_id]["role"] == "personal"
    assert by_id[out_id]["effective_amount"] == -50000
    # With the link gone the pair is suggested again, and nothing is listed.
    assert len(client.get("/transfers/suggestions").json()["suggestions"]) == 1
    assert client.get("/transfers").json() == {"transfers": []}


def test_delete_unknown_transfer_is_404() -> None:
    response = _client(_sqlite_engine()).delete(f"/transfers/{uuid4()}")
    assert response.status_code == 404


def test_reject_suppresses_the_suggestion_and_is_idempotent() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, in_id = _seed_pair(engine, user_id=dev_user_id)
    client = _client(engine)

    first = client.post(
        "/transfers/reject",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    )
    assert first.status_code == 204
    assert client.get("/transfers/suggestions").json() == {"suggestions": []}

    # Rejecting the same pair again changes nothing (idempotent).
    again = client.post(
        "/transfers/reject",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    )
    assert again.status_code == 204
    assert client.get("/transfers/suggestions").json() == {"suggestions": []}


def test_reject_is_order_independent() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, in_id = _seed_pair(engine, user_id=dev_user_id)
    client = _client(engine)

    # Reject naming the legs in the opposite order; the pair is still suppressed.
    response = client.post(
        "/transfers/reject",
        json={"outgoing_transaction_id": in_id, "incoming_transaction_id": out_id},
    )
    assert response.status_code == 204
    assert client.get("/transfers/suggestions").json() == {"suggestions": []}


def test_reject_the_same_transaction_twice_is_422() -> None:
    """Unlike confirm (guarded transitively by validate_transfer_pair's
    same-account check), reject had no such guard: naming one transaction
    as both legs would persist a self-referential dismissal row."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, _ = _seed_pair(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(
        "/transfers/reject",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": out_id},
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "same_transaction"


def test_confirm_unknown_transaction_is_404() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, _ = _seed_pair(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": str(uuid4())},
    )
    assert response.status_code == 404


def test_confirm_same_account_is_422() -> None:
    dev_user_id = get_settings().dev_user_id
    account = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        out = _tx(user_id=dev_user_id, account_id=account, amount=-50000, stable_key="TX-OUT")
        inc = _tx(user_id=dev_user_id, account_id=account, amount=50000, stable_key="TX-IN")
        session.add_all([out, inc])
        session.commit()
        out_id, in_id = str(out.id), str(inc.id)

    response = _client(engine).post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    )
    assert response.status_code == 422
    assert response.json()["detail"] == "same_account"


def test_confirm_already_linked_leg_is_409() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, in_id = _seed_pair(engine, user_id=dev_user_id)
    client = _client(engine)

    payload = {"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id}
    assert client.post("/transfers/confirm", json=payload).status_code == 201
    # Both legs are now linked, so confirming them again is a conflict.
    assert client.post("/transfers/confirm", json=payload).status_code == 409


def test_confirm_another_users_transaction_is_404() -> None:
    dev_user_id = get_settings().dev_user_id
    stranger_id = uuid4()
    engine = _sqlite_engine()
    with Session(engine) as session:
        mine = _tx(user_id=dev_user_id, account_id=uuid4(), amount=-50000, stable_key="TX-MINE")
        theirs = _tx(user_id=stranger_id, account_id=uuid4(), amount=50000, stable_key="TX-THEIRS")
        session.add_all([mine, theirs])
        session.commit()
        mine_id, theirs_id = str(mine.id), str(theirs.id)

    response = _client(engine).post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": mine_id, "incoming_transaction_id": theirs_id},
    )
    # The stranger's leg is invisible to this user, so it reads as "not found".
    assert response.status_code == 404


def test_confirm_links_a_free_form_pair_far_apart_across_manual_and_synced() -> None:
    """The free-form pairing the client's selection mode drives (ADR 0020 +
    ``docs/domain.md`` §Transfer).

    Confirming an explicit pair applies only the structural rules — not the
    amount tolerance or day window that bound automatic suggestions — and it
    does not care whether a leg sits on a synced or a manual account. Here the
    legs differ in magnitude by 499.90 EUR and in date by ~11 months, and one
    account is manual (``connection_id``/``identification_hash`` both ``NULL``,
    ADR 0020); ``POST /transfers/confirm`` still links them and zeroes both
    ``effective_amount``.
    """
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    synced_account_id = uuid4()
    manual_account_id = uuid4()
    with Session(engine) as session:
        session.add(
            AccountRow(
                id=synced_account_id,
                user_id=dev_user_id,
                connection_id=uuid4(),
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash="h-synced-1",
                name="TEST CURRENT 01",
                created_at=_DAY,
            )
        )
        session.add(
            AccountRow(
                id=manual_account_id,
                user_id=dev_user_id,
                connection_id=None,
                kind=AccountKind.WALLET,
                currency="EUR",
                identification_hash=None,
                name=None,
                alias="Investimenti",
                created_at=_DAY,
            )
        )
        out = _tx(
            user_id=dev_user_id, account_id=synced_account_id, amount=-50000, stable_key="TX-OUT"
        )
        out.booked_at = datetime(2026, 1, 1, tzinfo=UTC)
        out.value_date = datetime(2026, 1, 1, tzinfo=UTC)
        inc = TransactionRow(
            id=uuid4(),
            user_id=dev_user_id,
            account_id=manual_account_id,
            amount=10,
            currency="EUR",
            booked_at=None,
            value_date=datetime(2026, 12, 1, tzinfo=UTC),
            description="TEST CASH IN 01",
            display_description=None,
            status=TransactionStatus.BOOKED,
            stable_key="TX-IN-MANUAL",
            key_strategy=KeyStrategy.MANUAL,
        )
        session.add_all([out, inc])
        session.commit()
        out_id, in_id = str(out.id), str(inc.id)

    client = _client(engine)
    response = client.post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": out_id, "incoming_transaction_id": in_id},
    )

    assert response.status_code == 201
    by_id = {t["id"]: t for t in client.get("/transactions").json()["transactions"]}
    assert by_id[out_id]["role"] == "transfer"
    assert by_id[in_id]["role"] == "transfer"
    assert by_id[out_id]["effective_amount"] == 0
    assert by_id[in_id]["effective_amount"] == 0


def _seed_funded_payment(engine: Engine, *, user_id: UUID) -> tuple[str, str]:
    """Seed a card charge and an equal wallet payment; return (funding_id, funded_id).

    The canonical funded-payment shape: a Revolut-style card charge on a bank
    account that funds a PayPal-style wallet payment for the same amount, same
    day.
    """
    bank_account_id = uuid4()
    wallet_account_id = uuid4()
    with Session(engine) as session:
        session.add(
            AccountRow(
                id=bank_account_id,
                user_id=user_id,
                connection_id=uuid4(),
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash="h-bank-1",
                name="TEST CURRENT 01",
                created_at=_DAY,
            )
        )
        session.add(
            AccountRow(
                id=wallet_account_id,
                user_id=user_id,
                connection_id=uuid4(),
                kind=AccountKind.WALLET,
                currency="EUR",
                identification_hash="h-wallet-1",
                name="TEST WALLET 01",
                created_at=_DAY,
            )
        )
        funding = _tx(
            user_id=user_id, account_id=bank_account_id, amount=-1290, stable_key="TX-CARD"
        )
        funded = _tx(
            user_id=user_id, account_id=wallet_account_id, amount=-1290, stable_key="TX-WALLET"
        )
        session.add_all([funding, funded])
        session.commit()
        return str(funding.id), str(funded.id)


def test_suggests_a_funded_payment_when_a_wallet_leg_is_present() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    funding_id, funded_id = _seed_funded_payment(engine, user_id=dev_user_id)

    response = _client(engine).get("/transfers/suggestions")

    assert response.status_code == 200
    [suggestion] = response.json()["suggestions"]
    assert suggestion["kind"] == "funded_payment"
    assert suggestion["outgoing_transaction_id"] == funding_id
    assert suggestion["incoming_transaction_id"] == funded_id


def test_confirm_funded_payment_zeroes_only_the_funding_leg() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    funding_id, funded_id = _seed_funded_payment(engine, user_id=dev_user_id)
    client = _client(engine)

    response = client.post(
        "/transfers/confirm",
        json={
            "kind": "funded_payment",
            "outgoing_transaction_id": funding_id,
            "incoming_transaction_id": funded_id,
        },
    )

    assert response.status_code == 201
    assert response.json()["kind"] == "funded_payment"
    by_id = {t["id"]: t for t in client.get("/transactions").json()["transactions"]}
    # The funding leg is zeroed; the funded leg keeps its real amount and role,
    # so the payment counts exactly once.
    assert by_id[funding_id]["role"] == "funding"
    assert by_id[funding_id]["effective_amount"] == 0
    assert by_id[funded_id]["role"] == "personal"
    assert by_id[funded_id]["effective_amount"] == -1290
    # The pair is no longer suggested, and it is listed.
    assert client.get("/transfers/suggestions").json() == {"suggestions": []}
    assert len(client.get("/transfers").json()["transfers"]) == 1


def test_delete_funded_payment_reverts_the_funding_leg() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    funding_id, funded_id = _seed_funded_payment(engine, user_id=dev_user_id)
    client = _client(engine)

    transfer_id = client.post(
        "/transfers/confirm",
        json={
            "kind": "funded_payment",
            "outgoing_transaction_id": funding_id,
            "incoming_transaction_id": funded_id,
        },
    ).json()["id"]

    assert client.delete(f"/transfers/{transfer_id}").status_code == 204

    by_id = {t["id"]: t for t in client.get("/transactions").json()["transactions"]}
    assert by_id[funding_id]["role"] == "personal"
    assert by_id[funding_id]["effective_amount"] == -1290
    assert by_id[funded_id]["role"] == "personal"


def test_confirm_rejects_two_outflows_when_kind_is_two_sided() -> None:
    """The historical opposite-sign guard still stands for a two-sided confirm."""
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    funding_id, funded_id = _seed_funded_payment(engine, user_id=dev_user_id)

    response = _client(engine).post(
        "/transfers/confirm",
        json={"outgoing_transaction_id": funding_id, "incoming_transaction_id": funded_id},
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "not_opposite_signs"


def test_confirm_funded_payment_rejects_an_opposite_sign_pair() -> None:
    dev_user_id = get_settings().dev_user_id
    engine = _sqlite_engine()
    out_id, in_id = _seed_pair(engine, user_id=dev_user_id)

    response = _client(engine).post(
        "/transfers/confirm",
        json={
            "kind": "funded_payment",
            "outgoing_transaction_id": out_id,
            "incoming_transaction_id": in_id,
        },
    )

    assert response.status_code == 422
    assert response.json()["detail"] == "not_two_outflows"
