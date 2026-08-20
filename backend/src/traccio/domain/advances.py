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

from pydantic import BaseModel, ConfigDict

from traccio.domain.enums import AdvanceStatus, TransactionRole, TransactionStatus
from traccio.domain.models import Transaction
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
    ``.claude/rules/data-safety.md``).

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
    (see ``.claude/rules/data-safety.md``).

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
