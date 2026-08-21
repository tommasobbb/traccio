"""Request and response schemas for the transactions endpoints.

The ``amount``/``currency`` pair mirrors how persistence stores
:class:`~traccio.domain.money.Money` (two columns). ``effective_amount`` is
derived here from the single pure function
:func:`~traccio.domain.effective_amount.effective_amount` and returned alongside
``amount`` in the same ``currency``. The client renders it and never computes
spending from ``amount``, or advances and transfers would silently reappear as
spending (see the invariants in ``docs/architecture.md``). ``effective_category_id``
follows the same discipline via
:func:`~traccio.domain.categories.effective_category`, so the client never
re-implements the confirmed-else-suggested fallback.
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.categories import effective_category
from traccio.domain.effective_amount import effective_amount
from traccio.domain.enums import TransactionRole, TransactionStatus
from traccio.domain.models import Transaction
from traccio.domain.money import Money


class ConfirmCategoryRequest(BaseModel):
    """Body for confirming a transaction's category.

    Attributes
    ----------
    category_id : UUID
        The category to confirm. Must belong to the caller.
    """

    category_id: UUID


class TransactionResponse(BaseModel):
    """One transaction as returned to the client.

    A narrow projection of :class:`~traccio.domain.models.Transaction`:
    ``user_id`` (implied by the caller) and the deduplication internals
    (``entry_reference``, ``stable_key``, ``key_strategy``) are intentionally
    omitted. ``amount`` is integer minor units (cents); ``description`` is the
    bank's raw text — returned to its owner over authenticated transport, but
    never logged (see ``.claude/rules/data-safety.md``).

    Attributes
    ----------
    id : UUID
        Stable transaction identifier.
    account_id : UUID
        Account this movement belongs to.
    amount : int
        Value in the currency's minor unit (cents); negative means outgoing.
        What the bank reported; used only for balance reconciliation.
    effective_amount : int
        How much counts as real personal spending, derived from ``role`` and
        ``status`` (see :func:`~traccio.domain.effective_amount.effective_amount`).
        In the same ``currency`` as ``amount``. Every dashboard/budget total
        flows from this, never from ``amount``.
    currency : str
        ISO 4217 code of both ``amount`` and ``effective_amount``.
    booked_at : datetime or None
        Settlement time; ``None`` while pending.
    value_date : datetime or None
        When it affects the balance.
    description : str
        Raw text from the bank, preserved verbatim.
    display_description : str or None
        Cleaned-up description, produced separately (``None`` until built).
    status : TransactionStatus
        ``pending`` or ``booked``.
    role : TransactionRole
        How much counts as personal spending; defaults to ``personal``.
    suggested_category_id : UUID or None
        Written by the categorization engine, overwritten freely on every
        re-run. ``None`` until an engine exists (see ``tasks/backlog.md`` §M2).
    confirmed_category_id : UUID or None
        Set only by explicit user action via
        ``POST /transactions/{id}/category``; never by automation.
    effective_category_id : UUID or None
        The category that actually applies: ``confirmed`` if set, else
        ``suggested``, else ``None`` (see
        :func:`~traccio.domain.categories.effective_category`). The client
        renders this and never re-implements the fallback.
    """

    id: UUID
    account_id: UUID
    amount: int
    effective_amount: int
    currency: str
    booked_at: datetime | None
    value_date: datetime | None
    description: str
    display_description: str | None
    status: TransactionStatus
    role: TransactionRole
    suggested_category_id: UUID | None
    confirmed_category_id: UUID | None
    effective_category_id: UUID | None

    @classmethod
    def from_domain(
        cls, transaction: Transaction, *, advance_own_share: Money | None = None
    ) -> "TransactionResponse":
        """Project a domain :class:`~traccio.domain.models.Transaction`.

        Flattens ``money`` into ``amount``/``currency`` (the same split the
        persistence mapper uses) and drops the fields not meant for the client,
        so the projection is decided in one place.

        Parameters
        ----------
        transaction : Transaction
            The domain transaction to project.
        advance_own_share : Money or None, optional
            The signed spending share for an ``advance`` transaction (see
            :func:`~traccio.domain.advances.advance_spending_share`). Required
            only when ``transaction.role`` is ``advance``; the caller supplies it
            from the transaction's :class:`~traccio.domain.models.Advance`.

        Returns
        -------
        TransactionResponse
            The narrowed, client-facing view of ``transaction``.
        """
        # Derived in one place (the domain function), never recomputed elsewhere.
        effective = effective_amount(transaction, advance_own_share=advance_own_share)
        return cls(
            id=transaction.id,
            account_id=transaction.account_id,
            amount=transaction.money.amount,
            effective_amount=effective.amount,
            currency=transaction.money.currency,
            booked_at=transaction.booked_at,
            value_date=transaction.value_date,
            description=transaction.description,
            display_description=transaction.display_description,
            status=transaction.status,
            role=transaction.role,
            suggested_category_id=transaction.suggested_category_id,
            confirmed_category_id=transaction.confirmed_category_id,
            effective_category_id=effective_category(transaction),
        )


class TransactionsResponse(BaseModel):
    """Envelope for the transaction list.

    A wrapper object rather than a bare array leaves room for pagination
    metadata later without breaking the generated Swift client.

    Attributes
    ----------
    transactions : list[TransactionResponse]
        The requested page of the caller's transactions, most recent first.
    """

    transactions: list[TransactionResponse]


class PrunePendingResponse(BaseModel):
    """The outcome of pruning abandoned pending transactions.

    Only a count is returned, never row contents
    (``.claude/rules/data-safety.md``) — mirrors ``SyncResponse``'s
    counts-only shape (``api/schemas/connections.py``).

    Attributes
    ----------
    pruned : int
        How many pending transactions were deleted (see
        ``db/repositories.py::prune_stale_pending_transactions`` for the
        eligibility rule).
    """

    pruned: int
