"""Persisted :class:`~traccio.domain.models.Advance` and its participants/reimbursements."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, DateTime, ForeignKey, String, Text, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column
from traccio.domain.enums import AdvanceStatus


class AdvanceRow(Base):
    """Persisted :class:`~traccio.domain.models.Advance`.

    Records that the user paid for others on one outgoing transaction. Created
    only by an explicit user action, which also sets the transaction's ``role``
    to ``advance``; deleting it reverts the transaction to ``personal``.
    ``transaction_id`` is **unique** — a transaction has at most one advance.
    ``own_share`` is split into ``own_share_amount`` (positive magnitude, integer
    minor units) and ``own_share_currency``; ``receivable``/``outstanding`` are
    derived (see :mod:`traccio.domain.advances`), never stored.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    transaction_id : UUID
        The outgoing transaction this advance is on (foreign key, unique).
    own_share_amount : int
        The user's declared share, a positive magnitude in minor units.
    own_share_currency : str
        ISO 4217 code of ``own_share_amount`` (matches the transaction currency).
    status : AdvanceStatus
        Lifecycle state; ``open`` when created.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "advances"
    __table_args__ = (UniqueConstraint("transaction_id"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    transaction_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("transactions.id"))
    own_share_amount: Mapped[int] = mapped_column(BigInteger)
    own_share_currency: Mapped[str] = mapped_column(String(3))
    status: Mapped[AdvanceStatus] = mapped_column(_enum_column(AdvanceStatus))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class AdvanceParticipantRow(Base):
    """A person who owes the user back part of an :class:`AdvanceRow`.

    A free-text name plus an expected amount (a positive magnitude, split into
    ``expected_amount`` + ``expected_currency`` like :class:`~traccio.domain.money.Money`
    elsewhere). Belongs to exactly one advance; the parent's delete removes its
    participants (handled in the repository, not a DB cascade, to stay portable).

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    advance_id : UUID
        The advance this participant belongs to (foreign key, indexed).
    name : str
        The participant's plain name.
    expected_amount : int
        What the participant is expected to pay back, a positive magnitude.
    expected_currency : str
        ISO 4217 code of ``expected_amount``.
    """

    __tablename__ = "advance_participants"

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    advance_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("advances.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    expected_amount: Mapped[int] = mapped_column(BigInteger)
    expected_currency: Mapped[str] = mapped_column(String(3))


class ReimbursementRow(Base):
    """Persisted :class:`~traccio.domain.models.Reimbursement`.

    Records money paid back against one advance. Created only by an explicit user
    action. Either links a real incoming transaction (``transaction_id`` set,
    whose ``role`` the caller flips to ``reimbursement``) or is a manual cash
    entry (``transaction_id`` NULL). ``amount`` is a positive magnitude split into
    ``amount`` + ``currency`` like :class:`~traccio.domain.money.Money` elsewhere;
    the advance's ``outstanding`` and derived status follow from the sum of these,
    never stored on the advance.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    advance_id : UUID
        The advance this reimbursement pays back (foreign key, indexed).
    amount : int
        The amount paid back, a positive magnitude in minor units.
    currency : str
        ISO 4217 code of ``amount`` (matches the advance currency).
    transaction_id : UUID or None
        The linked incoming transaction, or ``None`` for a manual cash entry.
    participant_id : UUID or None
        The participant this reimbursement is explicitly attributed to, or
        ``None`` for an unattributed one (ADR 0012). A single reimbursement
        attributes to at most one participant — see
        :class:`~traccio.domain.models.Reimbursement`'s own docstring for why
        a real split is two rows, not a join table.
    note : str or None
        Optional free-text note.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "reimbursements"

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    advance_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("advances.id"), index=True)
    amount: Mapped[int] = mapped_column(BigInteger)
    currency: Mapped[str] = mapped_column(String(3))
    transaction_id: Mapped[UUID | None] = mapped_column(
        Uuid(), ForeignKey("transactions.id"), nullable=True
    )
    participant_id: Mapped[UUID | None] = mapped_column(
        Uuid(), ForeignKey("advance_participants.id"), nullable=True, index=True
    )
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
