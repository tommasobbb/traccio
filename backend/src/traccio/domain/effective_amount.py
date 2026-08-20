"""The ``effective_amount`` derivation.

The single place where ``effective_amount`` is computed. Per
``docs/architecture.md`` it is derived in exactly one pure function in
``domain/`` — never in a SQL view, a service, or the client — because every
dashboard, budget, and category total flows from it. Raw ``amount`` is what the
bank reported and is used only for balance reconciliation; mixing the two is the
most likely source of numbers that look wrong to the user.

This module imports nothing outside ``domain/``.
"""

from traccio.domain.enums import TransactionRole, TransactionStatus
from traccio.domain.models import Transaction
from traccio.domain.money import Money


def effective_amount(transaction: Transaction, *, advance_own_share: Money | None = None) -> Money:
    """Derive how much of ``transaction`` counts as real personal spending.

    The result is always expressed in the transaction's own currency. See
    ``docs/domain.md`` for the rule per role and status.

    Parameters
    ----------
    transaction : Transaction
        The movement to derive from. ``transaction.role`` selects the rule and
        ``transaction.status`` can override it (a ``rejected`` movement never
        settled, so it contributes zero regardless of role).
    advance_own_share : Money or None, optional
        Required only when ``transaction.role`` is
        :attr:`~traccio.domain.enums.TransactionRole.ADVANCE`: the part of the
        advance the user actually owes (declared by the user on the ``Advance``,
        never inferred). Ignored for every other role. Its currency must match
        the transaction's.

    Returns
    -------
    Money
        The effective amount, in ``transaction``'s currency.

    Raises
    ------
    ValueError
        If the transaction is an advance and ``advance_own_share`` is missing, or
        carries a different currency than the transaction. The message is stable
        and value-free (no amounts), per ``.claude/rules/data-safety.md``.
    """
    currency = transaction.money.currency

    # A refused or reversed movement never settled: it is not real spending,
    # whatever its role. This takes precedence over the role-based rule.
    if transaction.status is TransactionStatus.REJECTED:
        return Money(amount=0, currency=currency)

    match transaction.role:
        case TransactionRole.PERSONAL:
            return transaction.money
        case TransactionRole.TRANSFER:
            # Internal movement between the user's own accounts — neither income
            # nor spending on either leg.
            return Money(amount=0, currency=currency)
        case TransactionRole.REIMBURSEMENT:
            # Money paid back against an advance: it reduces a receivable, it is
            # not income.
            return Money(amount=0, currency=currency)
        case TransactionRole.ADVANCE:
            # Only the user's declared own share counts as spending.
            if advance_own_share is None:
                raise ValueError(
                    "advance transaction requires own_share to derive effective amount"
                )
            if advance_own_share.currency != currency:
                raise ValueError("advance own_share currency must match the transaction currency")
            return advance_own_share
