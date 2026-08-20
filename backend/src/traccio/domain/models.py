"""Core domain entities: User, Connection, Account, Transaction.

Pure Pydantic models with no dependency on any other project layer (no
SQLAlchemy, no FastAPI, no network). They stay testable with neither a database
nor a bank. Persistence and provider-shaped data live in ``db/`` and
``providers/`` respectively; these types are what those layers translate to and
from.

Identifiers and timestamps carry ``default_factory`` values for convenience in
tests and construction; the authoritative values are owned by the ``db/`` layer.
"""

from datetime import UTC, datetime
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field

from traccio.domain.enums import (
    AccountKind,
    ConnectionStatus,
    KeyStrategy,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.money import CurrencyCode, Money


def _now() -> datetime:
    """Return the current time as a timezone-aware UTC ``datetime``."""
    return datetime.now(UTC)


class User(BaseModel):
    """A person with an account in Traccio.

    Owns every other entity. A ``User`` is not a bank customer identity: one
    user may hold accounts at several banks. Every persisted query is scoped by
    ``user_id``; there is no path that returns rows across users.

    Attributes
    ----------
    id : UUID
        Stable identifier of the user.
    created_at : datetime
        When the user was created (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    created_at: datetime = Field(default_factory=_now)


class Connection(BaseModel):
    """One authorized link between a :class:`User` and one bank.

    Technically one PSD2 consent obtained through the aggregator. One consent
    typically exposes several accounts. Credentials and tokens are deliberately
    absent from this model: they are encrypted at rest in ``core``/``db`` and
    are never returned by any endpoint, not even to the owning user (see
    ``.claude/rules/data-safety.md``).

    Attributes
    ----------
    id : UUID
        Stable identifier of the connection.
    user_id : UUID
        Owning user.
    provider : str
        Aggregator/adapter that produced this connection (e.g.
        ``"enable_banking"``).
    institution_name : str
        Human-readable bank name for display.
    status : ConnectionStatus
        Lifecycle state of the consent.
    expires_at : datetime or None
        Consent expiry. Surfacing an upcoming expiry is a product concern, not
        an error case. ``None`` while pending.
    created_at : datetime
        When the connection was created (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    provider: str
    institution_name: str
    status: ConnectionStatus
    expires_at: datetime | None = None
    created_at: datetime = Field(default_factory=_now)


class Account(BaseModel):
    """A single balance-bearing account exposed by a bank.

    Attributes
    ----------
    id : UUID
        Stable identifier of the account within Traccio.
    user_id : UUID
        Owning user.
    connection_id : UUID
        Connection through which this account is currently reachable.
    kind : AccountKind
        ``current``, ``savings``, ``card``, or ``wallet``.
    currency : str
        The account's own ISO 4217 currency (a wallet may report ``XXX``). A
        transaction may carry a different one (foreign card purchases, or the
        per-transaction currency of a currency-agnostic wallet).
    identification_hash : str
        Derived stable identity used to match the account across consents.
        Bank-assigned account IDs are not stable, so they are not used here.
    name : str or None
        Optional display name.
    created_at : datetime
        When the account was first recorded (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    connection_id: UUID
    kind: AccountKind
    currency: CurrencyCode
    identification_hash: str
    name: str | None = None
    created_at: datetime = Field(default_factory=_now)


class Transaction(BaseModel):
    """A single movement on an :class:`Account`.

    Immutable once ``booked`` — corrections arrive as new transactions, never as
    edits. While ``pending``, amount and description may still change on
    settlement. ``money.amount`` is what the bank reported; how much counts as
    real personal spending is determined by ``role`` (the ``effective_amount``
    derivation is implemented later — see ``tasks/backlog.md`` M2).

    Attributes
    ----------
    id : UUID
        Stable identifier of the transaction within Traccio.
    user_id : UUID
        Owning user.
    account_id : UUID
        Account this movement belongs to.
    money : Money
        Amount and currency as reported by the bank (negative means outgoing).
    booked_at : datetime or None
        When the bank settled it; ``None`` while pending.
    value_date : datetime or None
        When it affects the balance; often differs from ``booked_at``.
    description : str
        Raw text from the bank, preserved verbatim and never rewritten in place.
    display_description : str or None
        Cleaned-up description produced separately from ``description``.
    status : TransactionStatus
        ``pending`` or ``booked``.
    role : TransactionRole
        How much counts as personal spending. Defaults to ``personal``; changed
        only by explicit user action or an accepted suggestion.
    entry_reference : str or None
        The bank's stable reference, when supplied. Preferred over the
        session-scoped transaction id for identity.
    stable_key : str
        The key used for idempotent deduplication.
    key_strategy : KeyStrategy
        Which strategy produced ``stable_key`` (bank reference vs derived hash).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    account_id: UUID
    money: Money
    booked_at: datetime | None = None
    value_date: datetime | None = None
    description: str
    display_description: str | None = None
    status: TransactionStatus
    role: TransactionRole = TransactionRole.PERSONAL
    entry_reference: str | None = None
    stable_key: str
    key_strategy: KeyStrategy


class Transfer(BaseModel):
    """A confirmed link between two transactions moving the same money.

    Two of the user's own accounts, opposite signs: the outgoing leg left one
    account and the incoming leg arrived in another (see ``docs/domain.md``). A
    ``Transfer`` exists only because the user confirmed a suggestion — detection
    never links (``docs/architecture.md``). Confirming sets both legs'
    ``role`` to :attr:`TransactionRole.TRANSFER`, which zeroes their
    ``effective_amount``; deleting the ``Transfer`` reverts both to
    ``personal``.

    Attributes
    ----------
    id : UUID
        Stable identifier of the transfer within Traccio.
    user_id : UUID
        Owning user. Both legs belong to this user.
    outgoing_transaction_id : UUID
        The negative leg (money left an account).
    incoming_transaction_id : UUID
        The positive leg (money arrived in another account).
    created_at : datetime
        When the transfer was confirmed (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    outgoing_transaction_id: UUID
    incoming_transaction_id: UUID
    created_at: datetime = Field(default_factory=_now)
