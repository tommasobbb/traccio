"""Enumerations shared across domain entities.

String-valued enums so they serialize to stable, human-readable values and
round-trip cleanly through JSON and the database. This module imports nothing
from other project layers.
"""

from enum import StrEnum


class ConnectionStatus(StrEnum):
    """Lifecycle state of a :class:`~traccio.domain.models.Connection`.

    Attributes
    ----------
    PENDING : str
        Authorization started but not yet completed.
    ACTIVE : str
        Consent granted and usable for syncing.
    EXPIRED : str
        Consent lifetime elapsed; the user must re-authorize from scratch.
    REVOKED : str
        Consent withdrawn by the user or the bank.
    ERROR : str
        The connection is in a failed state and cannot sync.
    """

    PENDING = "pending"
    ACTIVE = "active"
    EXPIRED = "expired"
    REVOKED = "revoked"
    ERROR = "error"


class AccountKind(StrEnum):
    """Kind of balance-bearing account exposed by a bank.

    Attributes
    ----------
    CURRENT : str
        A current (checking) account.
    SAVINGS : str
        A savings account.
    CARD : str
        A card account. Many banks invert the sign convention here; the
        provider adapter normalizes it (see ``docs/domain.md``).
    WALLET : str
        A currency-agnostic wallet (e.g. PayPal). It has no single account
        currency — the account may report ``XXX`` (ISO 4217 "no currency") —
        so the per-transaction currency is authoritative, not the account's.
    """

    CURRENT = "current"
    SAVINGS = "savings"
    CARD = "card"
    WALLET = "wallet"


class TransactionStatus(StrEnum):
    """Settlement state of a :class:`~traccio.domain.models.Transaction`.

    Attributes
    ----------
    PENDING : str
        Authorized but not yet settled; amount and description may still change.
    BOOKED : str
        Settled by the bank; immutable thereafter (corrections arrive as new
        transactions).
    REJECTED : str
        The movement was refused or reversed by the bank and never settled
        (ISO 20022 ``RJCT``). A terminal, immutable state like ``booked``; it is
        not real spending, so it contributes zero to ``effective_amount`` (M2).
    """

    PENDING = "pending"
    BOOKED = "booked"
    REJECTED = "rejected"


class TransactionRole(StrEnum):
    """How much of a transaction counts as real personal spending.

    The role drives ``effective_amount`` derivation (implemented later, in the
    role/effective-amount work — see ``tasks/backlog.md`` M2). It is set by the
    user or suggested by detection, never assumed silently.

    Attributes
    ----------
    PERSONAL : str
        Full amount counts. The default for every transaction.
    TRANSFER : str
        Internal movement between the user's own accounts; contributes zero.
    ADVANCE : str
        The user paid for others; only the user's own share counts.
    REIMBURSEMENT : str
        Money paid back against an advance; contributes zero.
    """

    PERSONAL = "personal"
    TRANSFER = "transfer"
    ADVANCE = "advance"
    REIMBURSEMENT = "reimbursement"


class AdvanceStatus(StrEnum):
    """Lifecycle state of an :class:`~traccio.domain.models.Advance`.

    Attributes
    ----------
    OPEN : str
        The user is still owed money; the default when an advance is created.
    SETTLED : str
        Fully paid back (reimbursements cover the receivable). Set when the
        reimbursement work lands.
    WRITTEN_OFF : str
        Given up on: the outstanding amount moves into the user's spending,
        because at that point it genuinely was spent. Set by the write-off flow.
    """

    OPEN = "open"
    SETTLED = "settled"
    WRITTEN_OFF = "written_off"


class ParticipantStatus(StrEnum):
    """Derived reimbursement status of one :class:`~traccio.domain.models.Participant`.

    Never stored — derived fresh from that participant's attributed
    reimbursements vs. their ``expected_amount`` (see
    :func:`traccio.domain.advances.derive_participant_states`, ADR 0012), the
    same discipline :class:`AdvanceStatus`'s own ``settled`` follows for the
    advance as a whole.

    Attributes
    ----------
    OUTSTANDING : str
        The participant has been reimbursed less than their expected share
        (or not attributed any reimbursement at all).
    SETTLED : str
        Reimbursed at least their expected share — an exact match or an
        overpayment both count, mirroring :class:`AdvanceStatus.SETTLED`'s own
        ``remaining <= 0`` boundary.
    """

    OUTSTANDING = "outstanding"
    SETTLED = "settled"


class EventStatus(StrEnum):
    """Lifecycle state of an :class:`~traccio.domain.models.Event`.

    An event is a reporting lens, not a role: its status organizes the user's
    view (a finished trip vs. an ongoing one) and never affects any
    transaction's ``effective_amount``.

    Attributes
    ----------
    ACTIVE : str
        Still accumulating members; the default when an event is created.
    CLOSED : str
        The occasion is over. Purely organizational — a closed event still
        reports its total and can be reopened.
    """

    ACTIVE = "active"
    CLOSED = "closed"


class KeyStrategy(StrEnum):
    """How a transaction's stable deduplication key was produced.

    Attributes
    ----------
    ENTRY_REFERENCE : str
        The bank supplied an ``entry_reference``; the preferred, reliable key.
    DERIVED_HASH : str
        No ``entry_reference`` was available; the key is a hash of
        ``(account_id, value_date, amount, currency, raw description)``. Lower
        confidence during deduplication, since near-identical entries collide.
    """

    ENTRY_REFERENCE = "entry_reference"
    DERIVED_HASH = "derived_hash"


class RuleMatchKind(StrEnum):
    """How a :class:`~traccio.domain.models.Rule` matches a transaction's
    ``description``.

    Matching is always case-insensitive over the raw bank text; see
    ``domain/rules.py::rule_matches``. Deliberately no regex — deterministic,
    user-legible predicates only (``tasks/ROADMAP.md``: "the rules engine is
    cheap and its accuracy is knowable").

    Attributes
    ----------
    CONTAINS : str
        The pattern appears anywhere in the description.
    STARTS_WITH : str
        The description begins with the pattern.
    EQUALS : str
        The description equals the pattern exactly (after casefolding).
    """

    CONTAINS = "contains"
    STARTS_WITH = "starts_with"
    EQUALS = "equals"


class ConsentState(StrEnum):
    """The *actual*, time-aware state of a consent — what the client renders.

    Derived by :func:`~traccio.domain.consent.consent_state`, never stored: a
    stored ``ConnectionStatus.ACTIVE`` says only what the provider last reported,
    not whether the 180-day consent window has since lapsed. This enum is what
    answers "is this consent still good right now" (see ``docs/openbanking.md``
    "Operational constraints" — expiry is a first-class product concern, not a
    tuning parameter).

    Attributes
    ----------
    PENDING : str
        Authorization started but not yet completed. Mirrors
        :attr:`ConnectionStatus.PENDING`.
    ACTIVE : str
        Consent usable for syncing and not close to expiry.
    EXPIRING_SOON : str
        Still usable, but ``expires_at`` falls within the warning window — the
        client should prompt the user to re-authorize before it lapses.
    EXPIRED : str
        Past ``expires_at``; syncing is refused until the user re-authorizes.
    REVOKED : str
        Consent withdrawn by the user or the bank. Mirrors
        :attr:`ConnectionStatus.REVOKED`.
    ERROR : str
        The connection is in a failed state and cannot sync. Mirrors
        :attr:`ConnectionStatus.ERROR`.
    """

    PENDING = "pending"
    ACTIVE = "active"
    EXPIRING_SOON = "expiring_soon"
    EXPIRED = "expired"
    REVOKED = "revoked"
    ERROR = "error"


class SyncTrigger(StrEnum):
    """What caused a :class:`~traccio.domain.models.SyncRun` to happen.

    Attributes
    ----------
    USER_PRESENT : str
        The user triggered it from the app and is actively waiting
        (``POST /connections/{id}/sync``). Not subject to the background
        fetch budget (``docs/openbanking.md``).
    BACKGROUND : str
        The scheduler triggered it with no user waiting
        (``services/scheduler.py``). Subject to the per-connection daily
        budget — see :func:`~traccio.domain.sync_schedule.sync_decision`.
    """

    USER_PRESENT = "user_present"
    BACKGROUND = "background"


class SyncRunOutcome(StrEnum):
    """What happened to one :class:`~traccio.domain.models.SyncRun`.

    Every attempt is recorded, including a skip — this is what makes the
    background fetch budget verifiable rather than merely theoretical (see
    ``docs/domain.md`` §Sync: "records what was attempted, when, and what
    failed").

    Attributes
    ----------
    SUCCESS : str
        The adapter was called and accounts/transactions were persisted.
    PROVIDER_FAILED : str
        The adapter call raised :class:`~traccio.providers.base.ProviderError`.
    SKIPPED_CONSENT : str
        Not attempted: the derived consent state had already lapsed.
    SKIPPED_BUDGET : str
        Not attempted: this connection already used its background fetch
        budget for the rolling 24h window.
    SKIPPED_INTERVAL : str
        Not attempted: the minimum interval since the last sync (any trigger)
        has not elapsed yet.
    """

    SUCCESS = "success"
    PROVIDER_FAILED = "provider_failed"
    SKIPPED_CONSENT = "skipped_consent"
    SKIPPED_BUDGET = "skipped_budget"
    SKIPPED_INTERVAL = "skipped_interval"
