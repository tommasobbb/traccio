"""Tests for the account write-path and credential-read repositories.

An in-memory SQLite engine backs the queries so no PostgreSQL is needed. Every
value is synthetic and the "credential" is an opaque placeholder, never a real
token (see ``.claude/rules/data-safety.md``).
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy import Engine, select
from sqlalchemy.orm import Session

from tests.conftest import sqlite_engine as _engine
from traccio.db.models import AccountRow, ConnectionRow, TransactionRow
from traccio.db.repositories import (
    get_connection_credentials,
    list_transactions_by_ids,
    list_transactions_in_period,
    mark_connection_synced,
    prune_stale_pending_transactions,
    set_account_alias,
    set_account_appearance,
    upsert_account,
    upsert_transaction,
)
from traccio.domain import Account, Transaction
from traccio.domain.enums import (
    AccountIcon,
    AccountKind,
    ConnectionStatus,
    KeyStrategy,
    PaletteColor,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.money import Money

_NOW = datetime(2026, 8, 21, 12, 0, 0, tzinfo=UTC)


def _account(
    *,
    user_id: UUID,
    connection_id: UUID,
    identification_hash: str = "HASH-01",
    name: str = "TEST CURRENT 01",
) -> Account:
    return Account(
        user_id=user_id,
        connection_id=connection_id,
        kind=AccountKind.CURRENT,
        currency="EUR",
        identification_hash=identification_hash,
        name=name,
    )


def _add_connection(
    engine: Engine,
    *,
    user_id: UUID,
    connection_id: UUID,
    status: ConnectionStatus,
    credentials: str | None,
) -> None:
    with Session(engine) as session:
        session.add(
            ConnectionRow(
                id=connection_id,
                user_id=user_id,
                provider="enable_banking",
                institution_name="TEST BANK 01",
                status=status,
                expires_at=None,
                created_at=datetime.now(UTC),
                encrypted_credentials=credentials,
                auth_state=None,
            )
        )
        session.commit()


def test_upsert_account_inserts_a_new_account() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        result = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        session.commit()
        inserted_id = result.id

    with Session(engine) as session:
        rows = list(session.scalars(select(AccountRow)).all())
    assert len(rows) == 1
    assert rows[0].id == inserted_id
    assert rows[0].identification_hash == "HASH-01"


def test_upsert_account_updates_in_place_without_duplicating() -> None:
    engine = _engine()
    user_id, first_conn, second_conn = uuid4(), uuid4(), uuid4()

    with Session(engine) as session:
        upsert_account(
            session, account=_account(user_id=user_id, connection_id=first_conn, name="OLD NAME")
        )
        session.commit()
    with Session(engine) as session:
        before = session.scalars(select(AccountRow)).one()
        original_id, original_created = before.id, before.created_at

    # The same account (same identification_hash) re-exposed via a new consent.
    with Session(engine) as session:
        upsert_account(
            session, account=_account(user_id=user_id, connection_id=second_conn, name="NEW NAME")
        )
        session.commit()

    with Session(engine) as session:
        rows = list(session.scalars(select(AccountRow)).all())
    assert len(rows) == 1
    row = rows[0]
    # Identity and creation time are preserved; the mutable fields are refreshed.
    assert row.id == original_id
    assert row.created_at == original_created
    assert row.connection_id == second_conn
    assert row.name == "NEW NAME"


def test_upsert_account_preserves_user_owned_fields() -> None:
    """A re-sync must never clobber ``alias``/``color``/``icon``.

    This is the load-bearing guarantee of the whole account-appearance
    feature: the user sets an alias and an appearance, a later sync brings a
    fresh provider ``name``, and only ``name`` should change.
    """
    engine = _engine()
    user_id, first_conn, second_conn = uuid4(), uuid4(), uuid4()

    with Session(engine) as session:
        inserted = upsert_account(
            session, account=_account(user_id=user_id, connection_id=first_conn, name="OLD NAME")
        )
        session.commit()
        account_id = inserted.id

    with Session(engine) as session:
        set_account_alias(
            session, user_id=user_id, account_id=account_id, alias="My salary account"
        )
        set_account_appearance(
            session,
            user_id=user_id,
            account_id=account_id,
            color=PaletteColor.TEAL,
            icon=AccountIcon.SAVINGS,
        )
        session.commit()

    # A later sync re-exposes the account through a new consent with a fresh
    # provider-supplied name.
    with Session(engine) as session:
        upsert_account(
            session, account=_account(user_id=user_id, connection_id=second_conn, name="NEW NAME")
        )
        session.commit()

    with Session(engine) as session:
        row = session.scalars(select(AccountRow).where(AccountRow.id == account_id)).one()
    assert row.name == "NEW NAME"
    assert row.connection_id == second_conn
    assert row.alias == "My salary account"
    assert row.color == PaletteColor.TEAL
    assert row.icon == AccountIcon.SAVINGS


def test_upsert_account_separates_users_with_the_same_hash() -> None:
    engine = _engine()
    shared_hash = "HASH-SHARED"
    user_a, user_b = uuid4(), uuid4()

    with Session(engine) as session:
        upsert_account(
            session,
            account=_account(
                user_id=user_a, connection_id=uuid4(), identification_hash=shared_hash
            ),
        )
        upsert_account(
            session,
            account=_account(
                user_id=user_b, connection_id=uuid4(), identification_hash=shared_hash
            ),
        )
        session.commit()

    with Session(engine) as session:
        rows = list(session.scalars(select(AccountRow)).all())
    # The uniqueness is (user_id, identification_hash): two users, two rows.
    assert len(rows) == 2
    assert {r.user_id for r in rows} == {user_a, user_b}


def _transaction(
    *,
    account_id: UUID,
    user_id: UUID,
    stable_key: str = "ENTRY-01",
    amount: int = -1234,
    description: str = "TEST MERCHANT 01",
    status: TransactionStatus = TransactionStatus.PENDING,
    role: TransactionRole = TransactionRole.PERSONAL,
) -> Transaction:
    return Transaction(
        user_id=user_id,
        account_id=account_id,
        money=Money(amount=amount, currency="EUR"),
        description=description,
        status=status,
        role=role,
        entry_reference=stable_key,
        stable_key=stable_key,
        key_strategy=KeyStrategy.ENTRY_REFERENCE,
    )


def test_upsert_transaction_inserts_a_new_transaction() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        result = upsert_transaction(
            session, transaction=_transaction(account_id=account.id, user_id=user_id), now=_NOW
        )
        session.commit()
        inserted_id = result.id

    with Session(engine) as session:
        rows = list(session.scalars(select(TransactionRow)).all())
    assert len(rows) == 1
    assert rows[0].id == inserted_id
    assert rows[0].stable_key == "ENTRY-01"
    # SQLite drops tzinfo on a DateTime(timezone=True) column; compare the
    # wall-clock value regardless.
    assert rows[0].last_synced_at is not None
    assert rows[0].last_synced_at.replace(tzinfo=None) == _NOW.replace(tzinfo=None)


def test_upsert_transaction_is_idempotent_on_account_and_stable_key() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        first = upsert_transaction(
            session, transaction=_transaction(account_id=account.id, user_id=user_id), now=_NOW
        )
        session.commit()
        first_id = first.id

    # Re-syncing the same entry (same account_id + stable_key) does not duplicate.
    with Session(engine) as session:
        again = upsert_transaction(
            session, transaction=_transaction(account_id=account.id, user_id=user_id), now=_NOW
        )
        session.commit()
        assert again.id == first_id

    with Session(engine) as session:
        rows = list(session.scalars(select(TransactionRow)).all())
    assert len(rows) == 1


def test_upsert_transaction_pending_becomes_booked_in_place() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        pending = upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id,
                user_id=user_id,
                amount=-1000,
                description="PENDING TEXT",
                status=TransactionStatus.PENDING,
            ),
            now=_NOW,
        )
        session.commit()
        pending_id = pending.id

    # The same movement settles: amount and description shift, status flips.
    with Session(engine) as session:
        upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id,
                user_id=user_id,
                amount=-1050,
                description="BOOKED TEXT",
                status=TransactionStatus.BOOKED,
            ),
            now=_NOW,
        )
        session.commit()

    with Session(engine) as session:
        rows = list(session.scalars(select(TransactionRow)).all())
    assert len(rows) == 1
    row = rows[0]
    assert row.id == pending_id  # same row, not a second one
    assert row.status is TransactionStatus.BOOKED
    assert row.amount == -1050
    assert row.description == "BOOKED TEXT"


def test_upsert_transaction_update_preserves_user_owned_fields() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id, user_id=user_id, status=TransactionStatus.PENDING
            ),
            now=_NOW,
        )
        session.commit()

    # The user (or detection) assigns a role, a cleaned description, and a
    # confirmed category on the row.
    confirmed_category_id = uuid4()
    with Session(engine) as session:
        row = session.scalars(select(TransactionRow)).one()
        row.role = TransactionRole.TRANSFER
        row.display_description = "Cleaned name"
        row.confirmed_category_id = confirmed_category_id
        session.commit()

    # A later sync updates the pending entry; it must not clobber those fields.
    with Session(engine) as session:
        upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id, user_id=user_id, status=TransactionStatus.BOOKED
            ),
            now=_NOW,
        )
        session.commit()

    with Session(engine) as session:
        row = session.scalars(select(TransactionRow)).one()
    assert row.status is TransactionStatus.BOOKED
    assert row.role is TransactionRole.TRANSFER
    assert row.display_description == "Cleaned name"
    assert row.confirmed_category_id == confirmed_category_id


def test_upsert_transaction_booked_row_is_immutable() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id,
                user_id=user_id,
                amount=-1234,
                description="ORIGINAL",
                status=TransactionStatus.BOOKED,
            ),
            now=_NOW,
        )
        session.commit()

    # A re-sync that reports different content for a booked entry is ignored,
    # but the row is stamped as re-observed (see prune_stale_pending_transactions:
    # last_synced_at means "a sync saw this," not "this row's content changed").
    later = _NOW + timedelta(days=1)
    with Session(engine) as session:
        upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id,
                user_id=user_id,
                amount=-9999,
                description="TAMPERED",
                status=TransactionStatus.BOOKED,
            ),
            now=later,
        )
        session.commit()

    with Session(engine) as session:
        row = session.scalars(select(TransactionRow)).one()
    assert row.amount == -1234
    assert row.description == "ORIGINAL"
    assert row.last_synced_at is not None
    assert row.last_synced_at.replace(tzinfo=None) == later.replace(tzinfo=None)


def test_upsert_transaction_rejected_row_is_immutable() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id,
                user_id=user_id,
                amount=-1234,
                description="ORIGINAL",
                status=TransactionStatus.REJECTED,
            ),
            now=_NOW,
        )
        session.commit()

    # A rejected entry is terminal like booked: a re-sync leaves it untouched.
    with Session(engine) as session:
        upsert_transaction(
            session,
            transaction=_transaction(
                account_id=account.id,
                user_id=user_id,
                amount=-9999,
                description="TAMPERED",
                status=TransactionStatus.REJECTED,
            ),
            now=_NOW,
        )
        session.commit()

    with Session(engine) as session:
        row = session.scalars(select(TransactionRow)).one()
    assert row.amount == -1234
    assert row.description == "ORIGINAL"


def test_upsert_transaction_same_key_on_different_accounts_are_separate() -> None:
    engine = _engine()
    user_id = uuid4()

    with Session(engine) as session:
        account_a = upsert_account(
            session,
            account=_account(user_id=user_id, connection_id=uuid4(), identification_hash="HASH-A"),
        )
        account_b = upsert_account(
            session,
            account=_account(user_id=user_id, connection_id=uuid4(), identification_hash="HASH-B"),
        )
        upsert_transaction(
            session,
            transaction=_transaction(account_id=account_a.id, user_id=user_id, stable_key="SHARED"),
            now=_NOW,
        )
        upsert_transaction(
            session,
            transaction=_transaction(account_id=account_b.id, user_id=user_id, stable_key="SHARED"),
            now=_NOW,
        )
        session.commit()

    with Session(engine) as session:
        rows = list(session.scalars(select(TransactionRow)).all())
    # Uniqueness is (account_id, stable_key): the same key on two accounts is two rows.
    assert len(rows) == 2
    assert {r.account_id for r in rows} == {account_a.id, account_b.id}


def test_list_transactions_by_ids_returns_a_map_keyed_by_id() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=user_id, connection_id=connection_id)
        )
        first = upsert_transaction(
            session,
            transaction=_transaction(account_id=account.id, user_id=user_id, stable_key="TX-A"),
            now=_NOW,
        )
        second = upsert_transaction(
            session,
            transaction=_transaction(account_id=account.id, user_id=user_id, stable_key="TX-B"),
            now=_NOW,
        )
        session.commit()

        found = list_transactions_by_ids(session, user_id=user_id, ids=[first.id, second.id])

    assert set(found) == {first.id, second.id}
    assert found[first.id].stable_key == "TX-A"
    assert found[second.id].stable_key == "TX-B"


def test_list_transactions_by_ids_omits_another_users_transaction() -> None:
    engine = _engine()
    owner_id, other_id, connection_id = uuid4(), uuid4(), uuid4()

    with Session(engine) as session:
        account = upsert_account(
            session, account=_account(user_id=owner_id, connection_id=connection_id)
        )
        mine = upsert_transaction(
            session, transaction=_transaction(account_id=account.id, user_id=owner_id), now=_NOW
        )
        session.commit()

        # Asking as a different user must not leak the row, the same
        # scoping get_transaction already enforces for a single id.
        found = list_transactions_by_ids(session, user_id=other_id, ids=[mine.id])

    assert found == {}


def test_list_transactions_by_ids_with_no_ids_makes_no_query() -> None:
    engine = _engine()
    with Session(engine) as session:
        assert list_transactions_by_ids(session, user_id=uuid4(), ids=[]) == {}


def test_get_connection_credentials_returns_active_ciphertext() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=user_id,
        connection_id=connection_id,
        status=ConnectionStatus.ACTIVE,
        credentials="CIPHERTEXT-01",
    )

    with Session(engine) as session:
        creds = get_connection_credentials(session, user_id=user_id, connection_id=connection_id)

    assert creds == "CIPHERTEXT-01"


def test_get_connection_credentials_ignores_pending_connection() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=user_id,
        connection_id=connection_id,
        status=ConnectionStatus.PENDING,
        credentials=None,
    )

    with Session(engine) as session:
        creds = get_connection_credentials(session, user_id=user_id, connection_id=connection_id)

    assert creds is None


def test_get_connection_credentials_is_user_scoped() -> None:
    engine = _engine()
    stranger_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=stranger_id,
        connection_id=connection_id,
        status=ConnectionStatus.ACTIVE,
        credentials="CIPHERTEXT-01",
    )

    with Session(engine) as session:
        creds = get_connection_credentials(session, user_id=uuid4(), connection_id=connection_id)

    # Another user's active connection is invisible to the scoped lookup.
    assert creds is None


# --- mark_connection_synced --------------------------------------------------


def test_mark_connection_synced_stamps_last_synced_at() -> None:
    engine = _engine()
    user_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=user_id,
        connection_id=connection_id,
        status=ConnectionStatus.ACTIVE,
        credentials="CIPHERTEXT-01",
    )

    with Session(engine) as session:
        row = session.get(ConnectionRow, connection_id)
        assert row is not None
        assert row.last_synced_at is None

    with Session(engine) as session:
        mark_connection_synced(session, user_id=user_id, connection_id=connection_id, now=_NOW)
        session.commit()

    with Session(engine) as session:
        row = session.get(ConnectionRow, connection_id)
        assert row is not None
        assert row.last_synced_at == _NOW.replace(tzinfo=None)


def test_mark_connection_synced_is_user_scoped() -> None:
    engine = _engine()
    stranger_id, connection_id = uuid4(), uuid4()
    _add_connection(
        engine,
        user_id=stranger_id,
        connection_id=connection_id,
        status=ConnectionStatus.ACTIVE,
        credentials="CIPHERTEXT-01",
    )

    with Session(engine) as session:
        # A different user names the stranger's connection id; the update
        # touches nothing.
        mark_connection_synced(session, user_id=uuid4(), connection_id=connection_id, now=_NOW)
        session.commit()

    with Session(engine) as session:
        row = session.get(ConnectionRow, connection_id)
        assert row is not None
        assert row.last_synced_at is None


# --- prune_stale_pending_transactions ---------------------------------------

_CUTOFF = datetime(2026, 8, 21, tzinfo=UTC)
_STALE = _CUTOFF - timedelta(days=1)  # older than cutoff: eligible
_FRESH = _CUTOFF + timedelta(days=1)  # newer than cutoff: not eligible


def _seed_transaction_row(
    engine: Engine,
    *,
    user_id: UUID,
    account_id: UUID,
    stable_key: str = "STALE-01",
    status: TransactionStatus = TransactionStatus.PENDING,
    role: TransactionRole = TransactionRole.PERSONAL,
    last_synced_at: datetime | None,
    event_id: UUID | None = None,
    confirmed_category_id: UUID | None = None,
) -> UUID:
    """Insert a TransactionRow directly, bypassing upsert_transaction, so every
    field prune_stale_pending_transactions cares about can be set independently
    of what a sync would ever produce in one call."""
    row_id = uuid4()
    with Session(engine) as session:
        session.add(
            TransactionRow(
                id=row_id,
                user_id=user_id,
                account_id=account_id,
                amount=-1234,
                currency="EUR",
                booked_at=None,
                value_date=None,
                description="TEST MERCHANT 01",
                status=status,
                role=role,
                entry_reference=stable_key,
                stable_key=stable_key,
                key_strategy=KeyStrategy.ENTRY_REFERENCE,
                last_synced_at=last_synced_at,
                event_id=event_id,
                confirmed_category_id=confirmed_category_id,
            )
        )
        session.commit()
    return row_id


def _remaining_ids(engine: Engine) -> set[UUID]:
    with Session(engine) as session:
        return set(session.scalars(select(TransactionRow.id)).all())


def test_prune_deletes_a_stale_eligible_pending_transaction() -> None:
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_transaction_row(
        engine, user_id=user_id, account_id=account_id, last_synced_at=_STALE
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    assert pruned == 1
    assert row_id not in _remaining_ids(engine)


def test_prune_skips_a_row_with_no_last_synced_at() -> None:
    """A row that predates the column is not yet eligible, not eligible by
    default — see db/repositories.py::prune_stale_pending_transactions."""
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_transaction_row(
        engine, user_id=user_id, account_id=account_id, last_synced_at=None
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    assert pruned == 0
    assert row_id in _remaining_ids(engine)


def test_prune_skips_a_row_still_inside_the_window() -> None:
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_transaction_row(
        engine, user_id=user_id, account_id=account_id, last_synced_at=_FRESH
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    assert pruned == 0
    assert row_id in _remaining_ids(engine)


def test_prune_skips_terminal_rows_even_if_stale() -> None:
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    booked_id = _seed_transaction_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="BOOKED-01",
        status=TransactionStatus.BOOKED,
        last_synced_at=_STALE,
    )
    rejected_id = _seed_transaction_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="REJECTED-01",
        status=TransactionStatus.REJECTED,
        last_synced_at=_STALE,
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    assert pruned == 0
    assert {booked_id, rejected_id} <= _remaining_ids(engine)


def test_prune_skips_a_non_personal_role() -> None:
    """A transfer/advance/reimbursement leg is never still `personal`
    (validate_advance/validate_reimbursement/validate_transfer_pair all
    require it), so a non-personal role is proof of a link this must not
    silently break."""
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_transaction_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        role=TransactionRole.ADVANCE,
        last_synced_at=_STALE,
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    assert pruned == 0
    assert row_id in _remaining_ids(engine)


def test_prune_skips_a_row_assigned_to_an_event() -> None:
    """Event membership is orthogonal to role (docs/domain.md), so it needs
    its own guard even though the row is still `personal`."""
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_transaction_row(
        engine, user_id=user_id, account_id=account_id, event_id=uuid4(), last_synced_at=_STALE
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    assert pruned == 0
    assert row_id in _remaining_ids(engine)


def test_prune_skips_a_row_with_a_confirmed_category() -> None:
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_transaction_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        confirmed_category_id=uuid4(),
        last_synced_at=_STALE,
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    assert pruned == 0
    assert row_id in _remaining_ids(engine)


def test_prune_is_user_scoped() -> None:
    engine = _engine()
    user_id, stranger_id = uuid4(), uuid4()
    account_id = uuid4()
    stranger_row_id = _seed_transaction_row(
        engine, user_id=stranger_id, account_id=account_id, last_synced_at=_STALE
    )

    with Session(engine) as session:
        pruned = prune_stale_pending_transactions(session, user_id=user_id, cutoff=_CUTOFF)
        session.commit()

    # A stranger's stale pending row is invisible to the user-scoped prune.
    assert pruned == 0
    assert stranger_row_id in _remaining_ids(engine)


# --- list_transactions_in_period ---------------------------------------------


def _seed_dated_row(
    engine: Engine,
    *,
    user_id: UUID,
    account_id: UUID,
    stable_key: str,
    booked_at: datetime | None,
    value_date: datetime | None,
) -> UUID:
    """Insert a TransactionRow with an explicit (booked_at, value_date) pair,
    bypassing upsert_transaction so both fields can be set independently."""
    row_id = uuid4()
    with Session(engine) as session:
        session.add(
            TransactionRow(
                id=row_id,
                user_id=user_id,
                account_id=account_id,
                amount=-1234,
                currency="EUR",
                booked_at=booked_at,
                value_date=value_date,
                description="TEST MERCHANT 01",
                status=TransactionStatus.BOOKED,
                role=TransactionRole.PERSONAL,
                entry_reference=stable_key,
                stable_key=stable_key,
                key_strategy=KeyStrategy.ENTRY_REFERENCE,
            )
        )
        session.commit()
    return row_id


def test_list_transactions_in_period_excludes_rows_before_start() -> None:
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    _seed_dated_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="BEFORE",
        booked_at=datetime(2026, 7, 31, tzinfo=UTC),
        value_date=None,
    )
    in_range_id = _seed_dated_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="IN-RANGE",
        booked_at=datetime(2026, 8, 15, tzinfo=UTC),
        value_date=None,
    )

    with Session(engine) as session:
        found = list_transactions_in_period(
            session,
            user_id,
            start=datetime(2026, 8, 1, tzinfo=UTC),
            end=datetime(2026, 9, 1, tzinfo=UTC),
        )

    assert [t.id for t in found] == [in_range_id]


def test_list_transactions_in_period_end_is_exclusive() -> None:
    """Half-open [start, end): a row landing exactly on `end` belongs to the
    next period, not this one — see ADR 0007."""
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    _seed_dated_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="ON-BOUNDARY",
        booked_at=datetime(2026, 9, 1, tzinfo=UTC),
        value_date=None,
    )

    with Session(engine) as session:
        found = list_transactions_in_period(
            session,
            user_id,
            start=datetime(2026, 8, 1, tzinfo=UTC),
            end=datetime(2026, 9, 1, tzinfo=UTC),
        )

    assert found == []


def test_list_transactions_in_period_start_is_inclusive() -> None:
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_dated_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="ON-START",
        booked_at=datetime(2026, 8, 1, tzinfo=UTC),
        value_date=None,
    )

    with Session(engine) as session:
        found = list_transactions_in_period(
            session,
            user_id,
            start=datetime(2026, 8, 1, tzinfo=UTC),
            end=datetime(2026, 9, 1, tzinfo=UTC),
        )

    assert [t.id for t in found] == [row_id]


def test_list_transactions_in_period_falls_back_to_value_date() -> None:
    """A still-pending row with no booked_at is dated by value_date instead —
    the same coalesce() already used to order the read-back endpoints."""
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_dated_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="PENDING",
        booked_at=None,
        value_date=datetime(2026, 8, 15, tzinfo=UTC),
    )

    with Session(engine) as session:
        found = list_transactions_in_period(
            session,
            user_id,
            start=datetime(2026, 8, 1, tzinfo=UTC),
            end=datetime(2026, 9, 1, tzinfo=UTC),
        )

    assert [t.id for t in found] == [row_id]


def test_list_transactions_in_period_row_with_no_date_is_excluded_by_a_bound() -> None:
    """coalesce(booked_at, value_date) is NULL when both are unset, so a bound
    on that side excludes it — it cannot be judged "in range"."""
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    _seed_dated_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="NO-DATE",
        booked_at=None,
        value_date=None,
    )

    with Session(engine) as session:
        found = list_transactions_in_period(
            session,
            user_id,
            start=datetime(2026, 8, 1, tzinfo=UTC),
            end=datetime(2026, 9, 1, tzinfo=UTC),
        )

    assert found == []


def test_list_transactions_in_period_row_with_no_date_is_included_with_no_bounds() -> None:
    engine = _engine()
    user_id, account_id = uuid4(), uuid4()
    row_id = _seed_dated_row(
        engine,
        user_id=user_id,
        account_id=account_id,
        stable_key="NO-DATE",
        booked_at=None,
        value_date=None,
    )

    with Session(engine) as session:
        found = list_transactions_in_period(session, user_id, start=None, end=None)

    assert [t.id for t in found] == [row_id]


def test_list_transactions_in_period_is_user_scoped() -> None:
    engine = _engine()
    user_id, stranger_id = uuid4(), uuid4()
    account_id = uuid4()
    _seed_dated_row(
        engine,
        user_id=stranger_id,
        account_id=account_id,
        stable_key="STRANGER",
        booked_at=datetime(2026, 8, 15, tzinfo=UTC),
        value_date=None,
    )

    with Session(engine) as session:
        found = list_transactions_in_period(session, user_id, start=None, end=None)

    assert found == []
