"""ORM tables mapping the domain entities to relational storage.

One table per domain entity. Rows are named with a ``Row`` suffix to keep them
distinct from the pure :mod:`traccio.domain.models` types they persist; the
translation between the two lives in :mod:`traccio.db.mappers`, never in
``domain``.

Enums are stored as their string ``.value`` in a portable ``VARCHAR`` (no native
PostgreSQL enum type and no check constraint — ``_enum_column`` leaves
``create_constraint`` at its SQLAlchemy default of ``False``), so adding a member
never requires a type migration. The column width is still sized to the longest
current member at the time of the migration that adds it, so a *later* member
longer than that (e.g. ``rejected`` vs. the original ``pending``/``booked``) does
need a width-widening migration — see
``d1f4b6a29c73_widen_transaction_status.py`` for the one this bit already.

Schema-level invariants (see ``docs/architecture.md``):

- Every table carries ``user_id``; queries are always scoped by it.
- ``transactions`` is unique on ``(account_id, stable_key)``, which is what
  makes sync idempotent — a re-import cannot duplicate a row.
"""

from datetime import date, datetime
from enum import StrEnum
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    Date,
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
    AdvanceStatus,
    ConnectionStatus,
    EventStatus,
    KeyStrategy,
    RuleMatchKind,
    TransactionRole,
    TransactionStatus,
)


def _enum_column(enum: type[StrEnum]) -> SAEnum:
    """Build a portable string-backed column type for a :class:`StrEnum`.

    Persists the enum's ``.value`` (not its member ``name``) as a plain
    ``VARCHAR``, rather than a native database enum type or a check constraint
    (``create_constraint`` is left at its SQLAlchemy default of ``False``).

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

    Two columns hold secret/transient material that is deliberately **absent
    from the domain model** (which never carries tokens — see
    ``docs/architecture.md``): ``encrypted_credentials`` and ``auth_state``.
    They are written by :mod:`traccio.db.repositories`, not by the mappers.

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
    country : str or None
        ISO 3166-1 alpha-2 country of the institution, as supplied when
        authorization started. ``None`` for connections created before this
        column existed.
    status : ConnectionStatus
        Consent lifecycle state, as last reported by the provider.
    expires_at : datetime or None
        Consent expiry; ``None`` while pending.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    encrypted_credentials : str or None
        The provider consent secret (Enable Banking ``session_id``) encrypted at
        rest with Fernet (see ``docs/decisions/0003-token-encryption-at-rest.md``).
        ``None`` while the connection is pending. Never logged, never returned by
        any endpoint.
    auth_state : str or None
        The anti-CSRF ``state`` issued when authorization started, used to match
        the SCA callback back to this pending connection. Unique; cleared to
        ``None`` once the connection is activated, re-set to a fresh value on
        re-authorization.
    last_synced_at : datetime or None
        When a sync last ran against this connection. ``None`` until the first
        sync; stamped by ``db/repositories.py::mark_connection_synced``.
    """

    __tablename__ = "connections"
    __table_args__ = (UniqueConstraint("auth_state"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    provider: Mapped[str] = mapped_column(String(64))
    institution_name: Mapped[str] = mapped_column(String(255))
    country: Mapped[str | None] = mapped_column(String(2), nullable=True)
    status: Mapped[ConnectionStatus] = mapped_column(_enum_column(ConnectionStatus))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    encrypted_credentials: Mapped[str | None] = mapped_column(Text, nullable=True)
    auth_state: Mapped[str | None] = mapped_column(String(128), nullable=True)
    last_synced_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


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


class TransferRow(Base):
    """Persisted :class:`~traccio.domain.models.Transfer`.

    A confirmed link between two transactions the user marked as the same money
    moving between their own accounts. Created only by an explicit user action
    (detection never links — see ``docs/architecture.md``); creating it also sets
    both legs' ``role`` to ``transfer``, and deleting it reverts them to
    ``personal``. Unique on ``(user_id, outgoing_transaction_id,
    incoming_transaction_id)`` so the same pair cannot be linked twice.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed). Both legs belong to this user.
    outgoing_transaction_id : UUID
        The negative leg (money left an account); foreign key to ``transactions``.
    incoming_transaction_id : UUID
        The positive leg (money arrived); foreign key to ``transactions``.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "transfers"
    __table_args__ = (
        UniqueConstraint("user_id", "outgoing_transaction_id", "incoming_transaction_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
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
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class EventRow(Base):
    """Persisted :class:`~traccio.domain.models.Event`.

    A user-defined grouping of transactions from one occasion. Membership lives
    on ``transactions.event_id`` (a transaction has at most one event), not in a
    join table. Deleting an event clears its members' ``event_id`` first (done in
    the repository, not a DB cascade, to stay portable) — the transactions
    survive. Nothing about the total is stored here; it is derived from the
    members (see :func:`~traccio.domain.events.event_total`).

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    name : str
        Human-readable name for the occasion.
    start_date : date or None
        Optional first day of the occasion (a hint, not a membership rule).
    end_date : date or None
        Optional last day of the occasion.
    status : EventStatus
        Lifecycle state; ``active`` when created.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "events"

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    start_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    end_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    status: Mapped[EventStatus] = mapped_column(_enum_column(EventStatus))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class CategoryRow(Base):
    """Persisted :class:`~traccio.domain.models.Category`.

    User-scoped and unique on ``(user_id, name)`` — two users may use the same
    name, but one user cannot have two categories with the same name. Seeded
    from :func:`~traccio.domain.categories.default_categories` at
    :func:`traccio.db.repositories.seed_default_categories`, but every row is
    owned by its user from creation; there is no shared "global" row.

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    name : str
        Human-readable name, unique per user.
    created_at : datetime
        Creation timestamp (timezone-aware, UTC).
    """

    __tablename__ = "categories"
    __table_args__ = (UniqueConstraint("user_id", "name"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class RuleRow(Base):
    """Persisted :class:`~traccio.domain.models.Rule`.

    Unique on ``(user_id, match_kind, pattern)`` — the same predicate and
    pattern twice has no meaning. Applied by
    :mod:`traccio.services.categorization` to write
    ``transactions.suggested_category_id`` via
    :func:`traccio.db.repositories.set_suggested_categories`; deleting the
    target category also deletes rules pointing at it (handled in the
    repository, not a DB cascade, to stay portable).

    Attributes
    ----------
    id : UUID
        Primary key.
    user_id : UUID
        Owning user (foreign key, indexed).
    category_id : UUID
        The category assigned when this rule matches (foreign key, indexed).
    match_kind : RuleMatchKind
        The predicate applied to a transaction's ``description``.
    pattern : str
        The text to match against, case-insensitive. Never logged (see
        ``.claude/rules/data-safety.md``).
    created_at : datetime
        Creation timestamp (timezone-aware, UTC); the tiebreak when two rules
        match with an equal-length pattern.
    """

    __tablename__ = "rules"
    __table_args__ = (UniqueConstraint("user_id", "match_kind", "pattern"),)

    id: Mapped[UUID] = mapped_column(Uuid(), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("users.id"), index=True)
    category_id: Mapped[UUID] = mapped_column(Uuid(), ForeignKey("categories.id"), index=True)
    match_kind: Mapped[RuleMatchKind] = mapped_column(_enum_column(RuleMatchKind))
    pattern: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
