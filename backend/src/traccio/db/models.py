"""ORM tables mapping the domain entities to relational storage.

One table per domain entity. Rows are named with a ``Row`` suffix to keep them
distinct from the pure :mod:`traccio.domain.models` types they persist; the
translation between the two lives in :mod:`traccio.db.mappers`, never in
``domain``.

Enums are stored as their string ``.value`` (portable ``VARCHAR`` with a check
constraint rather than a native PostgreSQL enum type), so adding a member does
not require a type migration and the stored values stay human-readable.

Schema-level invariants (see ``docs/architecture.md``):

- Every table carries ``user_id``; queries are always scoped by it.
- ``transactions`` is unique on ``(account_id, stable_key)``, which is what
  makes sync idempotent — a re-import cannot duplicate a row.
"""

from datetime import datetime
from enum import StrEnum
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    DateTime,
    ForeignKey,
    String,
    Text,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy import (
    Enum as SAEnum,
)
from sqlalchemy.orm import Mapped, mapped_column

from traccio.db.base import Base
from traccio.domain.enums import (
    AccountKind,
    ConnectionStatus,
    KeyStrategy,
    TransactionRole,
    TransactionStatus,
)


def _enum_column(enum: type[StrEnum]) -> SAEnum:
    """Build a portable string-backed column type for a :class:`StrEnum`.

    Persists the enum's ``.value`` (not its member ``name``) as a ``VARCHAR``
    with a check constraint, rather than a native database enum type.

    Parameters
    ----------
    enum : type[StrEnum]
        The domain enum to store.

    Returns
    -------
    Enum
        A SQLAlchemy ``Enum`` type persisting the string values.
    """
    return SAEnum(
        enum,
        native_enum=False,
        values_callable=lambda e: [member.value for member in e],
    )


class UserRow(Base):
    """Persisted :class:`~traccio.domain.models.User`.

    Attributes
    ----------
    id : UUID
        Primary key.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "users"

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ConnectionRow(Base):
    """Persisted :class:`~traccio.domain.models.Connection`.

    Bank credentials and tokens are deliberately absent: the at-rest encryption
    scheme is decided in M1 before anything is stored (see
    ``tasks/backlog.md``). Until then this table holds no secret material.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    provider : str
        Adapter that produced the connection (e.g. ``"enable_banking"``).
    institution_name : str
        Human-readable bank name for display.
    status : ConnectionStatus
        Consent lifecycle state.
    expires_at : datetime or None
        Consent expiry; ``None`` while pending.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "connections"

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    provider: Mapped[str] = mapped_column(String(64))
    institution_name: Mapped[str] = mapped_column(String(255))
    status: Mapped[ConnectionStatus] = mapped_column(_enum_column(ConnectionStatus))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class AccountRow(Base):
    """Persisted :class:`~traccio.domain.models.Account`.

    ``(user_id, identification_hash)`` is unique: an account has one row per
    stable identity, so it survives being re-exposed through a new consent
    without duplicating (see ``docs/architecture.md``).

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    connection_id : UUID
        Connection currently exposing this account (foreign key).
    kind : AccountKind
        ``current``, ``savings``, or ``card``.
    currency : str
        The account's own ISO 4217 currency.
    identification_hash : str
        Derived stable identity used to match the account across consents.
    name : str or None
        Optional display name.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "accounts"
    __table_args__ = (UniqueConstraint("user_id", "identification_hash"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    connection_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("connections.id"))
    kind: Mapped[AccountKind] = mapped_column(_enum_column(AccountKind))
    currency: Mapped[str] = mapped_column(String(3))
    identification_hash: Mapped[str] = mapped_column(String(128))
    name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


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
