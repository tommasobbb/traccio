"""Transfer queries: confirmed transfers and dismissals (ADR 0022)."""

from datetime import UTC, datetime
from typing import TYPE_CHECKING
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    row_to_transfer,
    transfer_to_row,
)
from traccio.db.models import (
    TransferDismissalRow,
    TransferRow,
)
from traccio.domain.models import (
    Transfer,
)


def create_transfer(session: Session, *, transfer: Transfer) -> Transfer:
    """Persist a confirmed transfer linking two transactions.

    Writes only the ``transfers`` row; setting the two legs' ``role`` is the
    caller's separate, explicit step (see :func:`set_transaction_role`). The
    caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    transfer : Transfer
        The domain transfer to store.

    Returns
    -------
    Transfer
        The persisted transfer.
    """
    row = transfer_to_row(transfer)
    session.add(row)
    return row_to_transfer(row)


def delete_transfer(session: Session, *, user_id: UUID, transfer_id: UUID) -> Transfer | None:
    """Delete a transfer and return it, scoped by ``user_id``.

    Returns the deleted transfer so the caller can revert both legs' ``role`` to
    ``personal`` (that role write is the caller's separate step). Returns
    ``None`` when no transfer with that id belongs to the user, so a request
    naming another user's (or an unknown) transfer changes nothing. The caller
    owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the transfer; the query and delete are scoped to it.
    transfer_id : UUID
        The transfer to delete.

    Returns
    -------
    Transfer or None
        The deleted transfer, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(TransferRow).where(
            TransferRow.id == transfer_id,
            TransferRow.user_id == user_id,
        )
    ).one_or_none()
    if row is None:
        return None
    transfer = row_to_transfer(row)
    session.delete(row)
    return transfer


def list_transfers(session: Session, user_id: UUID) -> list[Transfer]:
    """Return the user's confirmed transfers, oldest first.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transfers to return; the query is scoped to it.

    Returns
    -------
    list[Transfer]
        Domain transfers owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(TransferRow).where(TransferRow.user_id == user_id).order_by(TransferRow.created_at)
    ).all()
    return [row_to_transfer(row) for row in rows]


def transfer_exists_for_transaction(
    session: Session, *, user_id: UUID, transaction_id: UUID
) -> bool:
    """Return whether a transaction is already a leg of some transfer.

    Scoped by ``user_id``. Used to refuse confirming a transfer whose leg is
    already linked, so a transaction never belongs to two transfers.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose transfers to search; the query is scoped to it.
    transaction_id : UUID
        The transaction to look for on either leg.

    Returns
    -------
    bool
        ``True`` if the transaction is the outgoing or incoming leg of an
        existing transfer for this user.
    """
    row = session.scalars(
        select(TransferRow.id).where(
            TransferRow.user_id == user_id,
            (TransferRow.outgoing_transaction_id == transaction_id)
            | (TransferRow.incoming_transaction_id == transaction_id),
        )
    ).first()
    return row is not None


def create_transfer_dismissal(
    session: Session, *, user_id: UUID, transaction_id_a: UUID, transaction_id_b: UUID
) -> None:
    """Record that the user rejected a pair as a transfer (idempotent).

    The two ids are stored in canonical sorted order so the pair is
    order-independent, and a repeated rejection of the same pair is a no-op
    (idempotent, matching the unique constraint). The caller owns the transaction
    boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner recording the dismissal; the row is scoped to it.
    transaction_id_a : UUID
        One leg of the rejected pair.
    transaction_id_b : UUID
        The other leg of the rejected pair.
    """
    low, high = sorted((transaction_id_a, transaction_id_b))
    existing = session.scalars(
        select(TransferDismissalRow.id).where(
            TransferDismissalRow.user_id == user_id,
            TransferDismissalRow.transaction_id_a == low,
            TransferDismissalRow.transaction_id_b == high,
        )
    ).one_or_none()
    if existing is not None:
        return
    session.add(
        TransferDismissalRow(
            id=uuid4(),
            user_id=user_id,
            transaction_id_a=low,
            transaction_id_b=high,
            created_at=datetime.now(UTC),
        )
    )


def list_transfer_dismissals(session: Session, user_id: UUID) -> frozenset[frozenset[UUID]]:
    """Return the user's rejected transfer pairs as unordered id pairs.

    Feeds :func:`traccio.services.transfers.detect_transfers` so a rejected
    suggestion is not proposed again. Each pair is a two-element ``frozenset`` of
    transaction ids; the set is order-independent by construction.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose dismissals to return; the query is scoped to it.

    Returns
    -------
    frozenset[frozenset[UUID]]
        The dismissed pairs (empty if none).
    """
    rows = session.execute(
        select(
            TransferDismissalRow.transaction_id_a,
            TransferDismissalRow.transaction_id_b,
        ).where(TransferDismissalRow.user_id == user_id)
    ).all()
    return frozenset(frozenset((a, b)) for a, b in rows)
