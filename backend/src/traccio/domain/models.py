"""Core domain entities: User, Connection, Account, Transaction.

Pure Pydantic models with no dependency on any other project layer (no
SQLAlchemy, no FastAPI, no network). They stay testable with neither a database
nor a bank. Persistence and provider-shaped data live in ``db/`` and
``providers/`` respectively; these types are what those layers translate to and
from.

Identifiers and timestamps carry ``default_factory`` values for convenience in
tests and construction; the authoritative values are owned by the ``db/`` layer.
"""

from datetime import UTC, date, datetime
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, model_validator

from traccio.domain.enums import (
    AccountIcon,
    AccountKind,
    AdvanceStatus,
    CategoryIcon,
    ConnectionStatus,
    EventStatus,
    KeyStrategy,
    PaletteColor,
    RuleMatchKind,
    SyncRunOutcome,
    SyncTrigger,
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
    institution_logo : str or None
        The bank's logo URL, as supplied by the provider's institution list
        when the connection was started (Enable Banking's ASPSP ``logo``).
        ``None`` for connections created before this field existed, or if the
        provider had no logo — the client falls back to a lettermark.
        Cosmetic; nothing derives from it.
    country : str or None
        ISO 3166-1 alpha-2 country of the institution, as supplied when
        authorization started (``start_authorization`` needs it again on
        re-auth). ``None`` only for connections created before this field
        existed; a re-auth on one of those is refused (see
        ``api/routers/connections.py``) rather than guessing a country.
    status : ConnectionStatus
        Lifecycle state of the consent, as last reported by the provider. See
        ``domain/consent.py::consent_state`` for the actual, time-aware state —
        this field alone does not account for ``expires_at`` elapsing.
    expires_at : datetime or None
        Consent expiry, as reported by the provider. ``None`` while pending.
    created_at : datetime
        When the connection was created (timezone-aware, UTC).
    last_synced_at : datetime or None
        When a sync last ran against this connection (``POST
        /connections/{id}/sync``). ``None`` until the first sync. A display
        figure only — nothing derives from it.
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    provider: str
    institution_name: str
    institution_logo: str | None = None
    country: str | None = None
    status: ConnectionStatus
    expires_at: datetime | None = None
    created_at: datetime = Field(default_factory=_now)
    last_synced_at: datetime | None = None


class Account(BaseModel):
    """A single balance-bearing account: a bank feed, or a manual one.

    Most accounts project a bank feed obtained through a :class:`Connection`.
    A **manual** account (ADR 0020) has no connection and no provider-assigned
    identity — ``connection_id`` and ``identification_hash`` are both ``None``
    — and holds user-entered transactions. A ``model_validator`` enforces that
    the two fields are either both set or both ``None``; a half-populated
    account cannot be constructed. Which of the two an account is is derived by
    :func:`~traccio.domain.accounts.account_source`, never stored.

    Attributes
    ----------
    id : UUID
        Stable identifier of the account within Traccio.
    user_id : UUID
        Owning user.
    connection_id : UUID or None
        Connection through which this account is currently reachable, or
        ``None`` for a manual account.
    kind : AccountKind
        ``current``, ``savings``, ``card``, ``wallet``, or ``cash``. A
        separate axis from whether the account is synced or manual.
    currency : str
        The account's own ISO 4217 currency (a wallet may report ``XXX``). A
        transaction may carry a different one (foreign card purchases, or the
        per-transaction currency of a currency-agnostic wallet).
    identification_hash : str or None
        Derived stable identity used to match the account across consents, or
        ``None`` for a manual account. Bank-assigned account IDs are not
        stable, so they are not used here.
    name : str or None
        Provider-supplied display name (e.g. the bank's product name).
        Overwritten on every sync — see
        :func:`~traccio.db.repositories.upsert_account`. Never set by the
        user; contrast with ``alias``.
    alias : str or None
        User-chosen display name (ADR 0017). Survives sync — the one field
        ``upsert_account`` deliberately never touches. ``None`` until the user
        sets one, in which case :func:`~traccio.domain.accounts.display_name`
        falls back to ``name``.
    color : PaletteColor or None
        User-chosen colour token, or ``None`` before the user has picked one.
    icon : AccountIcon or None
        User-chosen icon token, or ``None`` before the user has picked one.
    created_at : datetime
        When the account was first recorded (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    connection_id: UUID | None = None
    kind: AccountKind
    currency: CurrencyCode
    identification_hash: str | None = None
    name: str | None = None
    alias: str | None = None
    color: PaletteColor | None = None
    icon: AccountIcon | None = None
    created_at: datetime = Field(default_factory=_now)

    @model_validator(mode="after")
    def _connection_and_identity_agree(self) -> "Account":
        """Reject a half-populated account.

        A synced account has both ``connection_id`` and ``identification_hash``;
        a manual account (ADR 0020) has neither. One without the other is an
        illegal state — a manual account with a stray identity would collide
        in the ``(user_id, identification_hash)`` unique index, and a synced
        account with no identity could not be matched across consents.
        """
        if (self.connection_id is None) != (self.identification_hash is None):
            raise ValueError(
                "connection_id and identification_hash must be both set "
                "(synced account) or both None (manual account)"
            )
        return self


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
    suggested_category_id : UUID or None
        Written by the categorization engine, overwritten freely on every
        re-run. ``None`` until an engine exists to fill it (see
        ``tasks/backlog.md`` §M2). Unlike ``event_id``, both category ids live
        on this domain model rather than staying db-only: a category is an
        attribute of the movement, like ``role``, not a cross-transaction
        grouping.
    confirmed_category_id : UUID or None
        Set only by direct user action; **never overwritten by any automated
        process** — any code path that writes it without a user action is a
        bug (see ``docs/domain.md`` §Category). The effective category is
        derived by :func:`~traccio.domain.categories.effective_category`
        (confirmed wins, else suggested), never recomputed inline.
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
    suggested_category_id: UUID | None = None
    confirmed_category_id: UUID | None = None


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


class Participant(BaseModel):
    """A named person who owes the user part of an :class:`Advance`.

    Free-text names, not :class:`User` records — enough to answer "who still
    owes me" without building a social graph (see ``docs/domain.md``). The
    ``expected_amount`` is a positive magnitude in the advance's currency; it is
    a hint for reconciliation, never validated against reimbursements.

    Attributes
    ----------
    id : UUID
        Stable identifier of the participant within Traccio — what a
        :class:`Reimbursement` attributes itself to via
        ``participant_id`` (see ADR 0012). Minted on creation like every
        other entity's ``id``; preserved on every read.
    name : str
        The participant's plain name.
    expected_amount : Money
        What this participant is expected to pay back, as a positive magnitude.
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    name: str
    expected_amount: Money


class Advance(BaseModel):
    """A transaction where the user paid for others and expects money back.

    The outgoing ``transaction``'s ``role`` becomes ``advance``, so only the
    user's declared ``own_share`` counts as spending (the rest is a receivable).
    An ``Advance`` exists only because the user created it — nothing is inferred
    (``docs/domain.md``). Deleting it reverts the transaction to ``personal``.

    ``own_share`` is stored as a **positive magnitude** in the transaction's
    currency (the cents the user actually owes); ``receivable`` and
    ``outstanding`` are **derived**, never stored — see
    :mod:`traccio.domain.advances`. Traccio tracks money owed *to* the user only;
    an advance is not a debt the user owes.

    Attributes
    ----------
    id : UUID
        Stable identifier of the advance within Traccio.
    user_id : UUID
        Owning user. The transaction belongs to this user.
    transaction_id : UUID
        The outgoing transaction whose ``role`` is ``advance``.
    own_share : Money
        The part of the advance the user actually owes, a positive magnitude in
        the transaction's currency. Declared by the user, never inferred.
    status : AdvanceStatus
        Lifecycle state; ``open`` when created.
    participants : list[Participant]
        Optional people who owe the user back, with an expected amount each.
    created_at : datetime
        When the advance was created (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    transaction_id: UUID
    own_share: Money
    status: AdvanceStatus = AdvanceStatus.OPEN
    participants: list[Participant] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=_now)


class Reimbursement(BaseModel):
    """Money paid back against an :class:`Advance`, reducing its receivable.

    One advance has many reimbursements; each belongs to exactly one advance
    (see ``docs/domain.md``). A reimbursement is either a real incoming
    transaction the user linked (``transaction_id`` set, whose ``role`` becomes
    ``reimbursement`` so it counts as neither income nor spending) or a cash
    payment the user recorded by hand (``transaction_id`` is ``None`` — cash
    never appears in a bank feed). Its ``amount`` is a **positive magnitude** in
    the advance's currency and is free: it is summed against the receivable, not
    validated against any participant's expected share. The advance's
    ``outstanding`` and derived ``status`` follow from the sum of these — nothing
    is stored on the advance itself (see :mod:`traccio.domain.advances`).

    ``participant_id`` is an optional, explicit attribution to one
    :class:`Participant` of the same advance (ADR 0012) — the user's own
    action at entry time, never inferred. A single reimbursement attributes to
    **at most one** participant; a real payment covering two people's shares
    is recorded as two separate reimbursements, one per person (see
    ``docs/domain.md`` §Reimbursement). Like ``amount``, it is never validated
    against that participant's ``expected_amount`` — a participant can be
    over- or under-reimbursed, same as the advance as a whole.

    Attributes
    ----------
    id : UUID
        Stable identifier of the reimbursement within Traccio.
    user_id : UUID
        Owning user. The advance and any linked transaction belong to this user.
    advance_id : UUID
        The advance this reimbursement pays back.
    amount : Money
        The amount paid back, a positive magnitude in the advance's currency.
    transaction_id : UUID or None
        The linked incoming transaction, or ``None`` for a manual cash entry.
    participant_id : UUID or None
        The participant this reimbursement is attributed to, or ``None`` for
        an unattributed one (the default, and the only option before ADR 0012).
    note : str or None
        Optional free-text note (e.g. "cash, split dinner"). Never validated.
    created_at : datetime
        When the reimbursement was recorded (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    advance_id: UUID
    amount: Money
    transaction_id: UUID | None = None
    participant_id: UUID | None = None
    note: str | None = None
    created_at: datetime = Field(default_factory=_now)


class Event(BaseModel):
    """A user-defined grouping of transactions from one real-world occasion.

    A trip, a renovation, a wedding — see ``docs/domain.md``. An event exists so
    the user can ask "what did this actually cost me?" and get an answer in terms
    of ``effective_amount``: a transfer between own accounts counts zero, an
    advance counts only the user's share, a reimbursement counts zero.

    An event is a **reporting lens, not a role**: membership is independent of a
    transaction's :class:`~traccio.domain.enums.TransactionRole` and never
    changes its ``effective_amount``. A transaction belongs to at most one event.
    The event total is a pure aggregation over its members
    (:func:`~traccio.domain.events.event_total`); nothing is stored on the event
    itself, and deleting an event removes only the grouping, never a transaction.

    Attributes
    ----------
    id : UUID
        Stable identifier of the event within Traccio.
    user_id : UUID
        Owning user. Every member transaction belongs to this user.
    name : str
        Human-readable name for the occasion (e.g. ``"Turkey 2026"``).
    start_date : date or None
        Optional first day of the occasion. A hint for the user, not a rule that
        assigns membership (a flight booked months earlier still belongs).
    end_date : date or None
        Optional last day of the occasion.
    status : EventStatus
        Lifecycle state; ``active`` when created. Purely organizational.
    created_at : datetime
        When the event was created (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    name: str
    start_date: date | None = None
    end_date: date | None = None
    status: EventStatus = EventStatus.ACTIVE
    created_at: datetime = Field(default_factory=_now)


class Category(BaseModel):
    """What kind of spending a transaction represents (groceries, rent, ...).

    User-scoped: renaming or deleting a category never affects another user's
    (see ``docs/domain.md`` §Category). A user is seeded from a shared default
    tree (:func:`~traccio.domain.categories.default_categories`) but the row
    itself belongs to them from creation — there is no shared "global" row.
    No ``kind``/``is_income`` flag: that is already carried by the sign of
    ``effective_amount``, so a second flag would be a second, desynchronisable
    source of truth.

    A **strict two-level hierarchy** (ADR 0018, 2026-08-25): ``parent_id`` is
    either ``None`` (a root) or the id of a root — never the id of another
    child. :func:`~traccio.domain.categories.validate_parent` is the one place
    that rule is enforced. Unique on ``(user_id, name)`` **globally**, not per
    parent — two children under different roots cannot share a name (see ADR
    0018 for the cost and why it was accepted).

    Attributes
    ----------
    id : UUID
        Stable identifier of the category within Traccio.
    user_id : UUID
        Owning user.
    name : str
        Human-readable name (e.g. ``"Groceries"``), unique per user across the
        whole tree.
    parent_id : UUID or None
        The root this category nests under, or ``None`` if it is itself a
        root.
    color : PaletteColor
        The category's colour (ADR 0017). Always set — every creation path
        resolves one, defaulting to the parent's own colour for a new child
        (:func:`~traccio.domain.categories.default_child_color`) or to
        :attr:`~traccio.domain.enums.PaletteColor.SLATE` for a root.
    icon : CategoryIcon or None
        The category's icon, or ``None`` before the user has picked one.
    created_at : datetime
        When the category was created (timezone-aware, UTC).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    name: str
    parent_id: UUID | None = None
    color: PaletteColor = PaletteColor.SLATE
    icon: CategoryIcon | None = None
    created_at: datetime = Field(default_factory=_now)


class Rule(BaseModel):
    """A user-defined mapping from a transaction pattern to a :class:`Category`.

    Applied by the categorization engine (:mod:`traccio.services.categorization`)
    to write ``Transaction.suggested_category_id`` — automation, never a user
    confirming an individual transaction (see ``docs/domain.md`` §Rule). A rule
    only ever writes the *suggested* layer; ``confirmed_category_id`` is set
    exclusively by direct user action on a transaction.

    Attributes
    ----------
    id : UUID
        Stable identifier of the rule within Traccio.
    user_id : UUID
        Owning user.
    category_id : UUID
        The category assigned when this rule matches.
    match_kind : RuleMatchKind
        The predicate applied to a transaction's ``description``.
    pattern : str
        The text to match against, case-insensitive. Never logged (see
        ``.claude/rules/data-safety.md`` — it is merchant/counterparty text).
    created_at : datetime
        When the rule was created (timezone-aware, UTC). Used as a tiebreak
        when two rules match with an equal-length pattern (see
        :func:`traccio.services.categorization.evaluation_order`).
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    category_id: UUID
    match_kind: RuleMatchKind
    pattern: str
    created_at: datetime = Field(default_factory=_now)


class SyncRun(BaseModel):
    """A record of one attempt to sync a :class:`Connection`.

    Written for every attempt, including a skip — that is what makes the
    per-connection background fetch budget verifiable rather than merely
    theoretical (``docs/domain.md`` §Sync, ADR 0010). Immutable once written:
    a sync run is a historical record, not a mutable job. Unlike
    ``Connection.last_synced_at`` (a single display-only stamp),
    ``sync_runs`` is the full history a budget decision reads from — see
    :func:`~traccio.domain.sync_schedule.sync_decision`.

    Attributes
    ----------
    id : UUID
        Stable identifier of the run.
    user_id : UUID
        Owning user.
    connection_id : UUID
        The connection this run attempted to sync.
    trigger : SyncTrigger
        Whether a user was waiting or the scheduler ran unattended.
    outcome : SyncRunOutcome
        What happened: synced, failed, or skipped (and why).
    started_at : datetime
        When the run began (timezone-aware, UTC).
    finished_at : datetime
        When the run concluded. Equal to ``started_at`` for a skip, since
        nothing was attempted.
    accounts_synced : int
        How many accounts were listed and upserted. Zero for a failure or a
        skip.
    transactions_synced : int
        How many transactions were fetched and upserted, across all accounts.
        Zero for a failure or a skip.
    error_reason : str or None
        A stable, value-free reason code (see ``.claude/rules/data-safety.md``
        — never a provider message or response body), set only when
        ``outcome`` is not ``success``.
    """

    model_config = ConfigDict(extra="forbid")

    id: UUID = Field(default_factory=uuid4)
    user_id: UUID
    connection_id: UUID
    trigger: SyncTrigger
    outcome: SyncRunOutcome
    started_at: datetime = Field(default_factory=_now)
    finished_at: datetime = Field(default_factory=_now)
    accounts_synced: int = 0
    transactions_synced: int = 0
    error_reason: str | None = None
