"""File-import queries: existing stable keys and the bulk insert (ADR 0023)."""

from collections.abc import Sequence
from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    transaction_to_row,
)
from traccio.db.models import (
    TransactionRow,
)
from traccio.domain.enums import (
    KeyStrategy,
)
from traccio.domain.models import (
    Transaction,
)


def imported_stable_keys(
    session: Session, *, user_id: UUID, account_ids: Sequence[UUID]
) -> set[str]:
    """Return the ``stable_key``s of already-imported rows on ``account_ids``.

    Used by both the import preview (to mark a row ``already_imported``) and
    the commit (to insert only the missing keys), so the two agree. Filtered to
    ``key_strategy == IMPORTED`` — a manual or synced row could never share a
    key with an import (``"{profile}:..."``), but the filter keeps the scan
    small and the intent explicit. Scoped by ``user_id``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the accounts; the query is scoped to it.
    account_ids : Sequence[UUID]
        The target accounts (the primary account, and the voucher account when
        a split profile is used).

    Returns
    -------
    set[str]
        Every ``stable_key`` already present from a prior import.
    """
    if not account_ids:
        return set()
    keys = session.scalars(
        select(TransactionRow.stable_key).where(
            TransactionRow.user_id == user_id,
            TransactionRow.account_id.in_(account_ids),
            TransactionRow.key_strategy == KeyStrategy.IMPORTED,
        )
    ).all()
    return set(keys)


def create_imported_transactions(session: Session, *, transactions: Sequence[Transaction]) -> int:
    """Insert imported movements onto manual accounts (ADR 0023).

    A plain bulk insert, like :func:`create_manual_transaction` and for the
    same reason: each row's ``stable_key`` (``"{profile}:{external_id}"``) is
    unique by construction, so there is nothing to reconcile. The caller has
    already filtered out keys that :func:`imported_stable_keys` reported as
    present, and verified every target account is manual and the user's.
    ``last_synced_at`` stays ``None`` — no sync observes these rows. The caller
    owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    transactions : Sequence[Transaction]
        Domain transactions built with ``status=booked``,
        ``key_strategy=IMPORTED`` and ``stable_key`` set to the movement's
        ``external_key``.

    Returns
    -------
    int
        The number of rows inserted (``len(transactions)``).
    """
    for transaction in transactions:
        session.add(transaction_to_row(transaction))
    return len(transactions)
