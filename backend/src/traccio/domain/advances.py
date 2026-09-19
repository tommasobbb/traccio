"""Pure advance arithmetic and validation.

An :class:`~traccio.domain.models.Advance` records that the user paid for others
on one outgoing transaction and is owed money back. This module holds the pure
derivations and the pair-validation rule — no I/O, imports only ``domain/`` — so
they are testable without a database and reused by the API layer.

Sign convention (see the plan and ``docs/domain.md``): ``own_share``,
``receivable`` and ``outstanding`` are **positive magnitudes** (the euros the
user owes / is owed). The one place a signed value is needed is
``effective_amount``, whose established contract takes the *signed* spending
share; :func:`advance_spending_share` does that single conversion, matching the
transaction's sign.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from traccio.domain.enums import (
    AdvanceStatus,
    ParticipantStatus,
    TransactionRole,
    TransactionStatus,
)
from traccio.domain.models import Participant, Reimbursement, Transaction
from traccio.domain.money import Money

# Stable, value-free reason codes for an invalid advance. Exposed so the API
# layer can map a rejection to an HTTP status without parsing a message.
REASON_NOT_PERSONAL = "not_personal"
REASON_REJECTED = "rejected"
REASON_NOT_OUTGOING = "not_outgoing"
REASON_CURRENCY_MISMATCH = "currency_mismatch"
REASON_SHARE_OUT_OF_RANGE = "share_out_of_range"

# Additional reason codes for an invalid reimbursement (see
# :func:`validate_reimbursement`).
REASON_NOT_INCOMING = "not_incoming"
REASON_NONPOSITIVE_AMOUNT = "nonpositive_amount"


class AdvanceError(ValueError):
    """A transaction and own_share cannot form a valid advance.

    Raised by :func:`validate_advance`. Carries a stable, value-free ``reason``
    (one of the ``REASON_*`` constants) so the API layer can map it to an HTTP
    status without inspecting the message. No amounts are included (see
    ``docs/engineering.md``).

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"invalid advance: {reason}")
        self.reason = reason


class ReimbursementError(ValueError):
    """A reimbursement cannot be recorded against an advance.

    Raised by :func:`validate_reimbursement`. Carries a stable, value-free
    ``reason`` (one of the module ``REASON_*`` constants) so the API layer can map
    it to an HTTP status without inspecting the message. No amounts are included
    (see ``docs/engineering.md``).

    Attributes
    ----------
    reason : str
        Machine-readable cause, one of the module ``REASON_*`` constants.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(f"invalid reimbursement: {reason}")
        self.reason = reason


def _require_same_currency(a: Money, b: Money) -> None:
    """Raise ``ValueError`` if two amounts are in different currencies."""
    if a.currency != b.currency:
        raise ValueError("advance amounts must share a currency")


def receivable(transaction: Transaction, own_share: Money) -> Money:
    """Return what the user is owed on an advance, as a positive magnitude.

    ``|amount| - own_share`` in the transaction's currency: the part of the
    outgoing movement that was not the user's own spending.

    Parameters
    ----------
    transaction : Transaction
        The advance's outgoing transaction.
    own_share : Money
        The user's declared share, a positive magnitude in the same currency.

    Returns
    -------
    Money
        The receivable, a positive magnitude in the transaction's currency.
    """
    _require_same_currency(transaction.money, own_share)
    return Money(
        amount=abs(transaction.money.amount) - own_share.amount,
        currency=own_share.currency,
    )


def outstanding(receivable_amount: Money, reimbursed: Money) -> Money:
    """Return what is still owed after reimbursements, as a positive magnitude.

    ``receivable - reimbursed``. Reimbursements do not exist yet, so callers pass
    a zero ``reimbursed`` this slice; the parameter is the seam the reimbursement
    work fills.

    Parameters
    ----------
    receivable_amount : Money
        The advance's receivable (see :func:`receivable`).
    reimbursed : Money
        The sum already paid back, a positive magnitude in the same currency.

    Returns
    -------
    Money
        The outstanding amount, a positive magnitude in the same currency.
    """
    _require_same_currency(receivable_amount, reimbursed)
    return Money(
        amount=receivable_amount.amount - reimbursed.amount,
        currency=receivable_amount.currency,
    )


def advance_spending_share(transaction: Transaction, own_share: Money) -> Money:
    """Return the user's share as a *signed* spending value.

    Converts the positive ``own_share`` magnitude to the transaction's sign (an
    advance is an outgoing movement, so this is negative), which is exactly what
    :func:`~traccio.domain.effective_amount.effective_amount` consumes for an
    ``advance`` role. This is the single place the magnitude becomes signed.

    Parameters
    ----------
    transaction : Transaction
        The advance's outgoing transaction (its sign is applied to the share).
    own_share : Money
        The user's declared share, a positive magnitude in the same currency.

    Returns
    -------
    Money
        The signed spending share, in the transaction's currency.
    """
    _require_same_currency(transaction.money, own_share)
    sign = -1 if transaction.money.amount < 0 else 1
    return Money(amount=sign * own_share.amount, currency=own_share.currency)


class AdvanceState(BaseModel):
    """The fully derived financial state of an advance at a point in time.

    Everything here is a pure function of the advance's transaction, the user's
    declared ``own_share``, the sum of reimbursements received, and whether the
    advance was written off — nothing is stored (see ``docs/domain.md`` and
    ADR 0004). ``receivable``, ``reimbursed``, ``outstanding`` and ``excess`` are
    **positive magnitudes**; ``spending_share`` is the single **signed** value the
    :func:`~traccio.domain.effective_amount.effective_amount` derivation consumes
    for an ``advance`` role.

    Attributes
    ----------
    receivable : Money
        What the user is owed in total, ``|amount| - own_share``.
    reimbursed : Money
        The sum already paid back (the input, echoed for the caller).
    outstanding : Money
        What is still owed, clamped at zero: ``max(0, receivable - reimbursed)``.
    excess : Money
        Over-reimbursement, ``max(0, reimbursed - receivable)`` — flagged for the
        user rather than silently absorbed.
    status : AdvanceStatus
        Derived lifecycle state: ``written_off`` when written off, else
        ``settled`` once reimbursements cover the receivable, else ``open``.
    spending_share : Money
        The user's real spending on the transaction, signed to match it. Equal to
        ``own_share`` normally; when written off, the outstanding amount (never
        paid back, so genuinely spent) is added on.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    receivable: Money
    reimbursed: Money
    outstanding: Money
    excess: Money
    status: AdvanceStatus
    spending_share: Money


def derive_advance(
    transaction: Transaction, own_share: Money, reimbursed: Money, *, written_off: bool
) -> AdvanceState:
    """Derive an advance's full financial state from its inputs.

    The single place receivable, reimbursements and the write-off flag are
    combined, so the API layer and the transaction projection never recompute
    these piecemeal. Reuses :func:`receivable`, :func:`outstanding` and
    :func:`advance_spending_share`; adds only the clamping, the over-reimbursement
    split, and the status/write-off rules.

    Parameters
    ----------
    transaction : Transaction
        The advance's outgoing transaction (its currency and sign are used).
    own_share : Money
        The user's declared share, a positive magnitude in the same currency.
    reimbursed : Money
        The sum already paid back, a positive magnitude in the same currency.
    written_off : bool
        Whether the user has written the advance off. When true the outstanding
        amount moves into spending and the status is ``written_off``.

    Returns
    -------
    AdvanceState
        The derived state (see the class for each field).

    Raises
    ------
    ValueError
        If ``own_share`` or ``reimbursed`` do not share the transaction's
        currency. The message is stable and value-free (no amounts).
    """
    _require_same_currency(transaction.money, own_share)
    _require_same_currency(transaction.money, reimbursed)
    currency = own_share.currency

    receivable_amount = receivable(transaction, own_share)
    remaining = receivable_amount.amount - reimbursed.amount
    outstanding_amount = Money(amount=max(0, remaining), currency=currency)
    excess_amount = Money(amount=max(0, -remaining), currency=currency)

    if written_off:
        status = AdvanceStatus.WRITTEN_OFF
        spending_magnitude = Money(
            amount=own_share.amount + outstanding_amount.amount, currency=currency
        )
    else:
        status = AdvanceStatus.SETTLED if remaining <= 0 else AdvanceStatus.OPEN
        spending_magnitude = own_share

    return AdvanceState(
        receivable=receivable_amount,
        reimbursed=reimbursed,
        outstanding=outstanding_amount,
        excess=excess_amount,
        status=status,
        spending_share=advance_spending_share(transaction, spending_magnitude),
    )


class ParticipantState(BaseModel):
    """The fully derived reimbursement state of one participant (ADR 0012).

    Everything here is a pure function of the participant's ``expected_amount``
    and the sum of reimbursements explicitly attributed to them — nothing is
    stored (mirrors :class:`AdvanceState`'s own discipline, one level down).
    An unattributed reimbursement (``participant_id`` is ``None``) counts
    toward the advance's own ``AdvanceState`` but never toward any
    ``ParticipantState``.

    Attributes
    ----------
    participant : Participant
        The participant this state is about.
    reimbursed : Money
        The sum of reimbursements attributed to this participant (the input,
        echoed for the caller).
    outstanding : Money
        What this participant still owes, clamped at zero:
        ``max(0, expected_amount - reimbursed)``.
    excess : Money
        Over-reimbursement for this participant specifically,
        ``max(0, reimbursed - expected_amount)`` — flagged, not absorbed, same
        as :class:`AdvanceState.excess`.
    status : ParticipantStatus
        ``settled`` once this participant's reimbursements cover their
        ``expected_amount``, else ``outstanding``.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    participant: Participant
    reimbursed: Money
    outstanding: Money
    excess: Money
    status: ParticipantStatus


def group_reimbursements_by_participant(
    reimbursements: Sequence[Reimbursement],
) -> dict[UUID, Money]:
    """Sum reimbursement amounts per participant, ignoring unattributed ones.

    Pure grouping over an already-loaded list — the caller decides how that
    list was obtained (a single advance's full reimbursement list in memory,
    or a page's worth); this function never touches the database. An empty
    input returns an empty map.

    Parameters
    ----------
    reimbursements : Sequence[Reimbursement]
        The reimbursements to group. Every one is assumed to share the same
        currency (the advance's), matching :func:`validate_reimbursement`'s
        own invariant — this function does not re-check it.

    Returns
    -------
    dict[UUID, Money]
        Participant id -> summed reimbursed amount. A reimbursement with
        ``participant_id is None`` contributes to no entry.
    """
    totals: dict[UUID, int] = {}
    currency: str | None = None
    for reimbursement in reimbursements:
        if reimbursement.participant_id is None:
            continue
        currency = reimbursement.amount.currency
        totals[reimbursement.participant_id] = (
            totals.get(reimbursement.participant_id, 0) + reimbursement.amount.amount
        )
    if currency is None:
        return {}
    return {
        participant_id: Money(amount=total, currency=currency)
        for participant_id, total in totals.items()
    }


def derive_participant_states(
    participants: Sequence[Participant],
    reimbursed_by_participant: Mapping[UUID, Money],
    *,
    currency: str,
) -> list[ParticipantState]:
    """Derive each participant's reimbursement state from their attributed total.

    Takes an already-aggregated map rather than the raw reimbursement list, so
    the same function serves both a single advance (aggregated in Python from
    its full reimbursement list, already loaded for :func:`derive_advance`'s
    own total) and a whole page of advances (aggregated by one grouped query
    for the page, never one query per row — see ADR 0004's "one aggregate
    query, not per row" and ADR 0012).

    Parameters
    ----------
    participants : Sequence[Participant]
        The advance's participants, in order.
    reimbursed_by_participant : Mapping[UUID, Money]
        Participant id -> summed reimbursed amount (see
        :func:`group_reimbursements_by_participant`). A participant with no
        entry is treated as having received nothing.
    currency : str
        The advance's currency — every participant's ``expected_amount`` and
        every entry in ``reimbursed_by_participant`` is assumed to already be
        in it (not re-validated here, same as :func:`derive_advance`).

    Returns
    -------
    list[ParticipantState]
        One state per input participant, in the same order.
    """
    states = []
    for participant in participants:
        reimbursed = reimbursed_by_participant.get(
            participant.id, Money(amount=0, currency=currency)
        )
        remaining = participant.expected_amount.amount - reimbursed.amount
        outstanding_amount = Money(amount=max(0, remaining), currency=currency)
        excess_amount = Money(amount=max(0, -remaining), currency=currency)
        status = ParticipantStatus.SETTLED if remaining <= 0 else ParticipantStatus.OUTSTANDING
        states.append(
            ParticipantState(
                participant=participant,
                reimbursed=reimbursed,
                outstanding=outstanding_amount,
                excess=excess_amount,
                status=status,
            )
        )
    return states


def validate_advance(transaction: Transaction, own_share: Money) -> None:
    """Check that a transaction and own_share may form an advance.

    Enforces the advance invariants: the transaction is still ``personal``, not
    ``rejected``, outgoing (a spend, ``amount < 0``); ``own_share`` shares the
    currency and is a magnitude in ``0 <= own_share <= |amount|`` (so the
    receivable is non-negative). ``own_share`` being user-declared is the
    caller's concern; this only checks it is well-formed.

    Parameters
    ----------
    transaction : Transaction
        The candidate transaction to mark as an advance.
    own_share : Money
        The user's declared share, a positive magnitude.

    Raises
    ------
    AdvanceError
        If any invariant is violated. The ``reason`` is a stable, value-free code
        (a module ``REASON_*`` constant); no financial values are included.
    """
    if transaction.status is TransactionStatus.REJECTED:
        raise AdvanceError(REASON_REJECTED)
    if transaction.role is not TransactionRole.PERSONAL:
        raise AdvanceError(REASON_NOT_PERSONAL)
    if transaction.money.amount >= 0:
        raise AdvanceError(REASON_NOT_OUTGOING)
    if own_share.currency != transaction.money.currency:
        raise AdvanceError(REASON_CURRENCY_MISMATCH)
    if not (0 <= own_share.amount <= abs(transaction.money.amount)):
        raise AdvanceError(REASON_SHARE_OUT_OF_RANGE)


def validate_reimbursement(
    amount: Money, advance_currency: str, *, transaction: Transaction | None
) -> None:
    """Check that a reimbursement may be recorded against an advance.

    Enforces that ``amount`` is a positive magnitude in the advance's currency.
    When a ``transaction`` is linked (a bank reimbursement rather than manual
    cash), it must be the incoming leg the user actually received: still
    ``personal``, not ``rejected``, incoming (``amount > 0``), and in the
    advance's currency. Reimbursement amounts are otherwise free — they are not
    validated against any participant's expected share (see ``docs/domain.md``).

    Parameters
    ----------
    amount : Money
        The amount paid back, expected as a positive magnitude.
    advance_currency : str
        The advance's ISO 4217 currency; the reimbursement must match it.
    transaction : Transaction or None
        The linked incoming transaction, or ``None`` for a manual cash entry.

    Raises
    ------
    ReimbursementError
        If any invariant is violated. The ``reason`` is a stable, value-free code
        (a module ``REASON_*`` constant); no financial values are included.
    """
    if amount.amount <= 0:
        raise ReimbursementError(REASON_NONPOSITIVE_AMOUNT)
    if amount.currency != advance_currency:
        raise ReimbursementError(REASON_CURRENCY_MISMATCH)
    if transaction is not None:
        if transaction.status is TransactionStatus.REJECTED:
            raise ReimbursementError(REASON_REJECTED)
        if transaction.role is not TransactionRole.PERSONAL:
            raise ReimbursementError(REASON_NOT_PERSONAL)
        if transaction.money.amount <= 0:
            raise ReimbursementError(REASON_NOT_INCOMING)
        if transaction.money.currency != advance_currency:
            raise ReimbursementError(REASON_CURRENCY_MISMATCH)


# --- Cross-advance roll-ups (ADR 0026) --------------------------------------
#
# "Who owes me, and how much in total" is a question about *all* the user's
# advances at once, not one advance. Traccio has no ``Person`` entity — a
# participant row is minted per advance (ADR 0012) — so the only way to add up
# one person across advances is to match on their name. These functions are the
# whole of that bridge: pure, name-keyed, and never converting between
# currencies (one row per currency, see ADR 0026).


def person_key(name: str) -> str:
    """Normalize a participant name for cross-advance grouping.

    Two participant rows on different advances are unrelated entities — there is
    no ``Person`` table (ADR 0026, ``docs/domain.md``). This is the only bridge:
    names differing solely in surrounding or repeated whitespace or in letter
    case collapse to one key, so ``"Marco"``, ``" marco  "`` and ``"MARCO"``
    roll up together. A genuine typo (``"Mardo"``) stays separate and cannot be
    merged after the fact — the accepted cost of not modelling people.

    Parameters
    ----------
    name : str
        The participant's plain name as entered.

    Returns
    -------
    str
        The grouping key: internal whitespace collapsed to single spaces,
        surrounding whitespace removed, case-folded.
    """
    return " ".join(name.split()).casefold()


class PersonSummary(BaseModel):
    """One person's receivable rolled up across every advance they appear on.

    A pure roll-up of :class:`ParticipantState` values that share a
    :func:`person_key` and a currency — nothing stored, mirroring
    :class:`AdvanceState`'s discipline one level up. Amounts are positive
    magnitudes in ``currency``.

    Attributes
    ----------
    name : str
        The display spelling: the first one seen for this key, with surrounding
        and repeated whitespace collapsed but case preserved.
    currency : str
        ISO 4217 code of ``expected``, ``reimbursed`` and ``outstanding``.
    expected : Money
        The sum of this person's ``expected_amount`` across their advances.
    reimbursed : Money
        The sum attributed back to this person across their advances.
    outstanding : Money
        What this person still owes in total: each advance's per-participant
        ``outstanding`` (already clamped at zero) summed, so an
        over-reimbursement on one advance never masks a debt on another.
    advance_count : int
        How many distinct advances this person appears on.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    name: str
    currency: str
    expected: Money
    reimbursed: Money
    outstanding: Money
    advance_count: int


@dataclass
class _PersonAccum:
    """Mutable per-person tally, used only while building :func:`summarize_people`."""

    name: str
    expected: int
    reimbursed: int
    outstanding: int
    advance_count: int


def summarize_people(
    states_by_advance: Sequence[Sequence[ParticipantState]],
) -> list[PersonSummary]:
    """Roll participant states up per person across advances.

    Parameters
    ----------
    states_by_advance : Sequence[Sequence[ParticipantState]]
        One inner sequence per advance — that advance's participant states, as
        returned by :func:`derive_participant_states`. Grouped by an *advance*
        boundary rather than flattened because :class:`Participant` carries no
        ``advance_id`` (``domain/models.py``); ``advance_count`` is the number
        of inner sequences a person appears in.

    Returns
    -------
    list[PersonSummary]
        One entry per ``(person_key, currency)``, ordered by ``outstanding``
        descending then display ``name``. A person appearing in two currencies
        yields two entries — amounts are never converted (ADR 0026).
    """
    accums: dict[tuple[str, str], _PersonAccum] = {}
    for advance_states in states_by_advance:
        seen_here: set[tuple[str, str]] = set()
        for state in advance_states:
            currency = state.outstanding.currency
            key = (person_key(state.participant.name), currency)
            accum = accums.get(key)
            if accum is None:
                accum = _PersonAccum(
                    name=" ".join(state.participant.name.split()),
                    expected=0,
                    reimbursed=0,
                    outstanding=0,
                    advance_count=0,
                )
                accums[key] = accum
            accum.expected += state.participant.expected_amount.amount
            accum.reimbursed += state.reimbursed.amount
            accum.outstanding += state.outstanding.amount
            if key not in seen_here:
                accum.advance_count += 1
                seen_here.add(key)

    summaries = [
        PersonSummary(
            name=accum.name,
            currency=currency,
            expected=Money(amount=accum.expected, currency=currency),
            reimbursed=Money(amount=accum.reimbursed, currency=currency),
            outstanding=Money(amount=accum.outstanding, currency=currency),
            advance_count=accum.advance_count,
        )
        for (_, currency), accum in accums.items()
    ]
    summaries.sort(key=lambda s: (-s.outstanding.amount, s.name.casefold()))
    return summaries


class ReceivableTotal(BaseModel):
    """What the user is still owed in one currency, across all advances.

    Attributes
    ----------
    currency : str
        ISO 4217 code these totals are in.
    outstanding : Money
        The sum of every *non-written-off* advance's ``outstanding`` in this
        currency — what the user is still owed overall. May exceed the sum of
        the per-person :class:`PersonSummary` outstandings: a reimbursement with
        no ``participant_id`` reduces the advance's outstanding but no person's
        (the rule :class:`ParticipantState` already follows). A written-off
        advance keeps its ``outstanding`` populated (the write-off moves that
        amount into spending, not to zero) but is deliberately excluded here —
        the user chose to stop expecting that money.
    expected : Money
        The sum of every *non-written-off* advance's ``receivable`` — the
        denominator for a "quanto è rientrato" progress bar across every
        advance (Anticipi's list screen, mirroring :class:`PersonSummary`'s own
        ``expected``/``reimbursed`` pair). Same written-off exclusion as
        ``outstanding``, for the same reason.
    reimbursed : Money
        The sum of every *non-written-off* advance's ``reimbursed`` — the
        numerator for that same progress bar. Can make ``expected -
        reimbursed`` diverge from ``outstanding`` when an advance carries
        ``excess`` (over-reimbursement): ``outstanding`` is clamped at zero,
        ``expected``/``reimbursed`` are not, exactly as already documented on
        :class:`PersonSummary`.
    open_advances : int
        How many advances in this currency are still ``open`` with a non-zero
        outstanding.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    currency: str
    outstanding: Money
    expected: Money
    reimbursed: Money
    open_advances: int


def total_receivable(states: Sequence[AdvanceState]) -> list[ReceivableTotal]:
    """Total what the user is still owed, per currency, across advances.

    Parameters
    ----------
    states : Sequence[AdvanceState]
        One per advance, as returned by :func:`derive_advance`. A ``settled``
        advance's ``outstanding`` is already zero, so it contributes nothing. A
        ``written_off`` advance's ``outstanding``/``receivable``/``reimbursed``
        stay populated on the state itself but are excluded here, all three —
        the user stopped expecting that money, so it should read out of the
        progress bar the same way it reads out of the headline figure. Either
        kind still keeps its currency present, as a zero row if nothing else is
        owed in it.

    Returns
    -------
    list[ReceivableTotal]
        One entry per currency that has at least one advance, ordered by
        currency code. Amounts are never converted between currencies (ADR 0026).
    """
    outstanding: dict[str, int] = {}
    expected: dict[str, int] = {}
    reimbursed: dict[str, int] = {}
    open_counts: dict[str, int] = {}
    for state in states:
        currency = state.outstanding.currency
        is_written_off = state.status is AdvanceStatus.WRITTEN_OFF
        outstanding[currency] = outstanding.get(currency, 0) + (
            0 if is_written_off else state.outstanding.amount
        )
        expected[currency] = expected.get(currency, 0) + (
            0 if is_written_off else state.receivable.amount
        )
        reimbursed[currency] = reimbursed.get(currency, 0) + (
            0 if is_written_off else state.reimbursed.amount
        )
        open_counts.setdefault(currency, 0)
        if state.status is AdvanceStatus.OPEN and state.outstanding.amount > 0:
            open_counts[currency] += 1
    return [
        ReceivableTotal(
            currency=currency,
            outstanding=Money(amount=outstanding[currency], currency=currency),
            expected=Money(amount=expected[currency], currency=currency),
            reimbursed=Money(amount=reimbursed[currency], currency=currency),
            open_advances=open_counts[currency],
        )
        for currency in sorted(outstanding)
    ]
