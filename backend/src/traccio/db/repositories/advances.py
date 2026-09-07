"""Advance and reimbursement queries (ADR 0004 / ADR 0012)."""

from typing import TYPE_CHECKING
from uuid import UUID

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

if TYPE_CHECKING:
    pass

from traccio.db.mappers import (
    advance_to_row,
    participant_to_row,
    reimbursement_to_row,
    row_to_advance,
    row_to_reimbursement,
)
from traccio.db.models import (
    AdvanceParticipantRow,
    AdvanceRow,
    ReimbursementRow,
)
from traccio.domain.enums import (
    AdvanceStatus,
)
from traccio.domain.models import (
    Advance,
    Reimbursement,
)
from traccio.domain.money import Money


def _participant_rows(
    session: Session, *, user_id: UUID, advance_id: UUID
) -> list[AdvanceParticipantRow]:
    """Return the participant rows of one advance, scoped by ``user_id``."""
    return list(
        session.scalars(
            select(AdvanceParticipantRow).where(
                AdvanceParticipantRow.user_id == user_id,
                AdvanceParticipantRow.advance_id == advance_id,
            )
        ).all()
    )


def create_advance(session: Session, *, advance: Advance) -> Advance:
    """Persist a new advance and its participants.

    Writes the ``advances`` row plus one ``advance_participants`` row per
    participant. Setting the transaction's ``role`` to ``advance`` is the caller's
    separate, explicit step (see :func:`set_transaction_role`). The caller owns
    the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    advance : Advance
        The domain advance to store (with its participants).

    Returns
    -------
    Advance
        The persisted advance.
    """
    session.add(advance_to_row(advance))
    for participant in advance.participants:
        session.add(participant_to_row(participant, user_id=advance.user_id, advance_id=advance.id))
    return advance


def get_advance(session: Session, *, user_id: UUID, advance_id: UUID) -> Advance | None:
    """Return a single advance (with participants) by id, scoped by ``user_id``.

    Returns ``None`` when no advance with that id belongs to the user.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advance; the query is scoped to it.
    advance_id : UUID
        The advance to fetch.

    Returns
    -------
    Advance or None
        The domain advance, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(AdvanceRow).where(AdvanceRow.id == advance_id, AdvanceRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    return row_to_advance(row, _participant_rows(session, user_id=user_id, advance_id=row.id))


def list_advances(session: Session, user_id: UUID) -> list[Advance]:
    """Return the user's advances (with participants), oldest first.

    Scoped by ``user_id``. Participants are fetched once and grouped in memory to
    avoid a per-advance query.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose advances to return; the query is scoped to it.

    Returns
    -------
    list[Advance]
        Domain advances owned by ``user_id`` (empty if none).
    """
    rows = session.scalars(
        select(AdvanceRow).where(AdvanceRow.user_id == user_id).order_by(AdvanceRow.created_at)
    ).all()
    participants: dict[UUID, list[AdvanceParticipantRow]] = {}
    for participant in session.scalars(
        select(AdvanceParticipantRow).where(AdvanceParticipantRow.user_id == user_id)
    ).all():
        participants.setdefault(participant.advance_id, []).append(participant)
    return [row_to_advance(row, participants.get(row.id, [])) for row in rows]


def delete_advance(session: Session, *, user_id: UUID, advance_id: UUID) -> Advance | None:
    """Delete an advance (and its participants) and return it, scoped by ``user_id``.

    Returns the deleted advance so the caller can revert the transaction's ``role``
    to ``personal`` (that role write is the caller's separate step). Returns
    ``None`` when no advance with that id belongs to the user. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advance; the query and delete are scoped to it.
    advance_id : UUID
        The advance to delete.

    Returns
    -------
    Advance or None
        The deleted advance, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(AdvanceRow).where(AdvanceRow.id == advance_id, AdvanceRow.user_id == user_id)
    ).one_or_none()
    if row is None:
        return None
    participant_rows = _participant_rows(session, user_id=user_id, advance_id=row.id)
    advance = row_to_advance(row, participant_rows)
    for participant in participant_rows:
        session.delete(participant)
    session.delete(row)
    return advance


def advance_exists_for_transaction(
    session: Session, *, user_id: UUID, transaction_id: UUID
) -> bool:
    """Return whether a transaction already has an advance.

    Scoped by ``user_id``. Used to refuse creating a second advance on the same
    transaction.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose advances to search; the query is scoped to it.
    transaction_id : UUID
        The transaction to look for.

    Returns
    -------
    bool
        ``True`` if an advance for this user already references the transaction.
    """
    row = session.scalars(
        select(AdvanceRow.id).where(
            AdvanceRow.user_id == user_id,
            AdvanceRow.transaction_id == transaction_id,
        )
    ).first()
    return row is not None


def set_advance_status(
    session: Session, *, user_id: UUID, advance_id: UUID, status: AdvanceStatus
) -> None:
    """Set an advance's stored ``status``, scoped by ``user_id``.

    Only the ``written_off`` transition (and its reversal to ``open``) is stored;
    ``settled`` is derived from reimbursements, never written here (see ADR 0004).
    Scoped by ``user_id``; a no-op if no row matches. The caller owns the
    transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the advance; the update is scoped to it.
    advance_id : UUID
        The advance whose status to set.
    status : AdvanceStatus
        The new stored status.
    """
    session.execute(
        update(AdvanceRow)
        .where(AdvanceRow.id == advance_id, AdvanceRow.user_id == user_id)
        .values(status=status)
    )


def create_reimbursement(session: Session, *, reimbursement: Reimbursement) -> Reimbursement:
    """Persist a new reimbursement against an advance.

    Writes only the ``reimbursements`` row; flipping a linked transaction's
    ``role`` to ``reimbursement`` is the caller's separate, explicit step (see
    :func:`set_transaction_role`). The caller owns the transaction boundary and
    commits.

    Parameters
    ----------
    session : Session
        Active database session.
    reimbursement : Reimbursement
        The domain reimbursement to store.

    Returns
    -------
    Reimbursement
        The persisted reimbursement.
    """
    session.add(reimbursement_to_row(reimbursement))
    return reimbursement


def list_reimbursements(
    session: Session, *, user_id: UUID, advance_id: UUID
) -> list[Reimbursement]:
    """Return one advance's reimbursements, oldest first, scoped by ``user_id``.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose reimbursements to return; the query is scoped to it.
    advance_id : UUID
        The advance whose reimbursements to list.

    Returns
    -------
    list[Reimbursement]
        The advance's reimbursements, oldest first (empty if none).
    """
    rows = session.scalars(
        select(ReimbursementRow)
        .where(
            ReimbursementRow.user_id == user_id,
            ReimbursementRow.advance_id == advance_id,
        )
        .order_by(ReimbursementRow.created_at)
    ).all()
    return [row_to_reimbursement(row) for row in rows]


def delete_reimbursement(
    session: Session, *, user_id: UUID, advance_id: UUID, reimbursement_id: UUID
) -> Reimbursement | None:
    """Delete a reimbursement and return it, scoped by ``user_id``.

    Returns the deleted reimbursement so the caller can revert a linked
    transaction's ``role`` to ``personal`` (that role write is the caller's
    separate step). Returns ``None`` when no matching reimbursement belongs to the
    user and advance. The caller owns the transaction boundary and commits.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner of the reimbursement; the query and delete are scoped to it.
    advance_id : UUID
        The advance the reimbursement belongs to.
    reimbursement_id : UUID
        The reimbursement to delete.

    Returns
    -------
    Reimbursement or None
        The deleted reimbursement, or ``None`` if not found for this user.
    """
    row = session.scalars(
        select(ReimbursementRow).where(
            ReimbursementRow.id == reimbursement_id,
            ReimbursementRow.user_id == user_id,
            ReimbursementRow.advance_id == advance_id,
        )
    ).one_or_none()
    if row is None:
        return None
    reimbursement = row_to_reimbursement(row)
    session.delete(row)
    return reimbursement


def sum_reimbursements_by_advance(session: Session, user_id: UUID) -> dict[UUID, Money]:
    """Return the total reimbursed per advance for a user, as ``Money``.

    Aggregates in SQL (one query, not one per advance) so the advances list and
    the transaction projection can derive ``outstanding``/spending without an
    N+1. All of one advance's reimbursements share its currency (enforced when
    they are created), so grouping by ``(advance_id, currency)`` yields one row
    per advance.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose reimbursements to sum; the query is scoped to it.

    Returns
    -------
    dict[UUID, Money]
        Advance id to the sum reimbursed (positive magnitude). Advances with no
        reimbursement are absent from the map.
    """
    rows = session.execute(
        select(
            ReimbursementRow.advance_id,
            ReimbursementRow.currency,
            func.sum(ReimbursementRow.amount),
        )
        .where(ReimbursementRow.user_id == user_id)
        .group_by(ReimbursementRow.advance_id, ReimbursementRow.currency)
    ).all()
    return {
        advance_id: Money(amount=int(total), currency=currency)
        for advance_id, currency, total in rows
    }


def sum_reimbursements_by_participant(session: Session, user_id: UUID) -> dict[UUID, Money]:
    """Return the total reimbursed per participant for a user, as ``Money``.

    The per-participant sibling of :func:`sum_reimbursements_by_advance` (ADR
    0012), same shape and same reason: one aggregate query for a whole page of
    advances, never one per participant. A reimbursement with no
    ``participant_id`` is excluded — it counts toward the advance's own total
    but toward no participant's.

    Parameters
    ----------
    session : Session
        Active database session.
    user_id : UUID
        Owner whose reimbursements to sum; the query is scoped to it.

    Returns
    -------
    dict[UUID, Money]
        Participant id to the sum reimbursed (positive magnitude).
        Participants with no attributed reimbursement are absent from the map.
    """
    rows = session.execute(
        select(
            ReimbursementRow.participant_id,
            ReimbursementRow.currency,
            func.sum(ReimbursementRow.amount),
        )
        .where(ReimbursementRow.user_id == user_id, ReimbursementRow.participant_id.is_not(None))
        .group_by(ReimbursementRow.participant_id, ReimbursementRow.currency)
    ).all()
    return {
        participant_id: Money(amount=int(total), currency=currency)
        for participant_id, currency, total in rows
        if participant_id is not None
    }
