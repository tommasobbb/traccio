"""Persisted :class:`~traccio.domain.models.Transaction`."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, DateTime, ForeignKey, String, Text, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column
from traccio.domain.enums import KeyStrategy, TransactionRole, TransactionStatus


class TransactionRow(Base):
    """Persisted :class:`~traccio.domain.models.Transaction`.

    :class:`~traccio.domain.money.Money` is split into ``amount`` (integer minor
    units) and ``currency``; :mod:`traccio.db.mappers` recomposes it. The
    unique constraint on ``(account_id, stable_key)`` enforces idempotent sync
    at the schema level, not in application code.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    account_id : UUID
        Account this movement belongs to (foreign key, indexed).
    amount : int
        Value in the currency's minor unit (cents); may be negative.
    currency : str
        ISO 4217 code of ``amount``.
    booked_at : datetime or None
        Settlement time; ``None`` while pending.
    value_date : datetime or None
        When it affects the balance.
    description : str
        Raw text from the bank, preserved verbatim.
    display_description : str or None
        Cleaned-up description, produced separately.
    status : TransactionStatus
        ``pending`` or ``booked``.
    role : TransactionRole
        How much counts as personal spending; defaults to ``personal``.
    entry_reference : str or None
        The bank's stable reference, when supplied.
    stable_key : str
        Key used for idempotent deduplication.
    key_strategy : KeyStrategy
        Which strategy produced ``stable_key``.
    event_id : UUID or None
        The event this transaction is grouped under, or ``None``. A transaction
        belongs to at most one event; membership is set and cleared by explicit
        user action and is orthogonal to ``role`` (an event is a reporting lens,
        not a role). Deliberately **absent from the domain model** — it is a
        db-only grouping column (like ``connections.auth_state``), managed by the
        repository, not the mappers.
    suggested_category_id : UUID or None
        The engine-suggested category, or ``None``. Unlike ``event_id``, this
        **is** on the domain model (see :class:`~traccio.domain.models.Transaction`)
        because a category is an attribute of the movement, not a
        cross-transaction grouping. Read by
        :mod:`traccio.db.mappers`; never written by it — the only writer is
        :func:`traccio.db.repositories.set_suggested_categories`, called from
        ``POST /rules/apply`` (:mod:`traccio.services.categorization`).
    confirmed_category_id : UUID or None
        The user-confirmed category, or ``None``. Also on the domain model, for
        the same reason as ``suggested_category_id``. The **only** writer is
        :func:`traccio.db.repositories.set_confirmed_category`, called only from
        an explicit user action — never from sync or detection.
    last_synced_at : datetime or None
        When a sync last observed this row (insert, a pending refresh, or a
        terminal row re-seen unchanged). ``None`` for a row that predates this
        column. Deliberately **absent from the domain model** — like
        ``event_id``, this is sync-process bookkeeping, not something a bank
        reports. The only writer is
        :func:`traccio.db.repositories.upsert_transaction`; the only reader
        besides that is :func:`traccio.db.repositories.prune_stale_pending_transactions`,
        which ages a still-``pending`` row off it (``docs/domain.md``:
        "pending transactions that neither settle nor reappear within a
        defined window are dropped").
    """

    __tablename__ = "transactions"
    __table_args__ = (UniqueConstraint("account_id", "stable_key"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    account_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("accounts.id"), index=True)
    amount: Mapped[int] = mapped_column(BigInteger)
    currency: Mapped[str] = mapped_column(String(3))
    booked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    value_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    description: Mapped[str] = mapped_column(Text)
    display_description: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[TransactionStatus] = mapped_column(_enum_column(TransactionStatus))
    role: Mapped[TransactionRole] = mapped_column(
        _enum_column(TransactionRole), default=TransactionRole.PERSONAL
    )
    entry_reference: Mapped[str | None] = mapped_column(String(255), nullable=True)
    stable_key: Mapped[str] = mapped_column(String(128))
    key_strategy: Mapped[KeyStrategy] = mapped_column(_enum_column(KeyStrategy))
    event_id: Mapped[UUID | None] = mapped_column(
        Uuid(), ForeignKey("events.id"), nullable=True, index=True
    )
    suggested_category_id: Mapped[UUID | None] = mapped_column(
        Uuid(), ForeignKey("categories.id"), nullable=True, index=True
    )
    confirmed_category_id: Mapped[UUID | None] = mapped_column(
        Uuid(), ForeignKey("categories.id"), nullable=True, index=True
    )
    last_synced_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, index=True
    )
