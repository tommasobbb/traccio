"""Persisted :class:`~traccio.domain.models.Transfer` and its dismissals."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column
from traccio.domain.enums import TransferKind


class TransferRow(Base):
    """Persisted :class:`~traccio.domain.models.Transfer`.

    A confirmed link between two transactions the user marked as the same money
    moving between their own accounts. Created only by an explicit user action
    (detection never links — see ``docs/architecture.md``); deleting it reverts
    every leg it touched to ``personal``. Unique on ``(user_id,
    outgoing_transaction_id, incoming_transaction_id)`` so the same pair cannot
    be linked twice.

    ``kind`` (see :class:`~traccio.domain.enums.TransferKind`) decides the
    legs' signs and which legs are zeroed: ``two_sided`` links an opposite-sign
    pair and sets **both** to ``role=transfer``; ``funded_payment`` links two
    outflows and sets only ``outgoing_transaction_id`` (the funding leg) to
    ``role=funding``, leaving ``incoming_transaction_id`` (the real expense)
    ``personal``.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed). Both legs belong to this user.
    kind : TransferKind
        The pairing kind; ``two_sided`` for every row created before this
        column existed (backfilled by migration).
    outgoing_transaction_id : UUID
        Two-sided: the negative leg. Funded payment: the funding leg (set to
        ``role=funding``). Foreign key to ``transactions``.
    incoming_transaction_id : UUID
        Two-sided: the positive leg. Funded payment: the funded leg, the real
        expense (left ``personal``). Foreign key to ``transactions``.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "transfers"
    __table_args__ = (
        UniqueConstraint("user_id", "outgoing_transaction_id", "incoming_transaction_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    kind: Mapped[TransferKind] = mapped_column(
        _enum_column(TransferKind), default=TransferKind.TWO_SIDED
    )
    outgoing_transaction_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("transactions.id"))
    incoming_transaction_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("transactions.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class TransferDismissalRow(Base):
    """A pair of transactions the user rejected as a transfer.

    Recorded when the user rejects a transfer suggestion, so detection does not
    propose the same pair again (``GET /transfers/suggestions`` recomputes from
    scratch each call). The two ids are stored in canonical sorted order
    (``transaction_id_a`` < ``transaction_id_b``) so the pair is
    order-independent, and the row is unique on
    ``(user_id, transaction_id_a, transaction_id_b)`` so repeated rejections are
    idempotent. Purely a suppression marker: it is not a domain entity.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    transaction_id_a : UUID
        The lower of the two transaction ids (canonical order).
    transaction_id_b : UUID
        The higher of the two transaction ids (canonical order).
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "transfer_dismissals"
    __table_args__ = (UniqueConstraint("user_id", "transaction_id_a", "transaction_id_b"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    transaction_id_a: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("transactions.id"))
    transaction_id_b: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("transactions.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
