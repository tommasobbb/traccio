"""Persisted :class:`~traccio.domain.models.Account`."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, ForeignKey, String, Text, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.db.models._common import _enum_column, _token_column
from traccio.domain.enums import AccountIcon, AccountKind, PaletteColor


class AccountRow(Base):
    """Persisted :class:`~traccio.domain.models.Account`.

    ``(user_id, identification_hash)`` is unique: a synced account has one row
    per stable identity, so it survives being re-exposed through a new consent
    without duplicating (see ``docs/architecture.md``). A **manual** account
    (ADR 0020) has ``connection_id`` and ``identification_hash`` both ``NULL``;
    since ``NULL != NULL`` in SQL, the unique constraint does not constrain
    manual rows and a sync's ``upsert_account`` can never match one.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    connection_id : UUID or None
        Connection currently exposing this account (foreign key), or ``NULL``
        for a manual account.
    kind : AccountKind
        ``current``, ``savings``, ``card``, ``wallet``, or ``cash``.
    currency : str
        The account's own ISO 4217 currency.
    identification_hash : str or None
        Opaque stable identity Enable Banking assigns per account, used to
        match it across consents; ``NULL`` for a manual account.
        Provider-controlled, not a hash this codebase generates — length is
        not something we can bound, so it is ``Text`` like
        ``ConnectionRow.encrypted_credentials``, not a guessed ``VARCHAR``
        size (a first real Revolut sync exceeded a prior ``VARCHAR(128)`` on
        Postgres, invisible on SQLite which ignores declared VARCHAR length —
        see migration ``e2c4a8f1b6d3_widen_identification_hash``).
    name : str or None
        Provider-supplied display name. Overwritten on every sync by
        :func:`~traccio.db.repositories.upsert_account` — never user-owned.
    alias : str or None
        User-chosen display name (ADR 0017). ``upsert_account`` never writes
        this column; it is the one field a sync must leave untouched.
    color : PaletteColor or None
        User-chosen colour token, ``None`` until set.
    icon : AccountIcon or None
        User-chosen icon token, ``None`` until set.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "accounts"
    __table_args__ = (UniqueConstraint("user_id", "identification_hash"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    connection_id: Mapped[UUID | None] = mapped_column(
        Uuid(), ForeignKey("connections.id"), nullable=True
    )
    kind: Mapped[AccountKind] = mapped_column(_enum_column(AccountKind))
    currency: Mapped[str] = mapped_column(String(3))
    identification_hash: Mapped[str | None] = mapped_column(Text, nullable=True)
    name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    alias: Mapped[str | None] = mapped_column(Text, nullable=True)
    color: Mapped[PaletteColor | None] = mapped_column(_token_column(PaletteColor), nullable=True)
    icon: Mapped[AccountIcon | None] = mapped_column(_token_column(AccountIcon), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
