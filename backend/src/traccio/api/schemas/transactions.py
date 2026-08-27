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

from pydantic import BaseModel, StrictInt

from traccio.domain.categories import effective_category
from traccio.domain.effective_amount import effective_amount
from traccio.domain.enums import TransactionRole, TransactionStatus
from traccio.domain.models import Transaction
from traccio.domain.money import CurrencyCode, Money


class ConfirmCategoryRequest(BaseModel):
    """Body for confirming a transaction's category.

    Attributes
    ----------
    category_id : UUID
        The category to confirm. Must belong to the caller.
    """

    category_id: UUID


class CreateManualTransactionRequest(BaseModel):
    """Body for creating a movement on a manual account (ADR 0020).

    Only manual accounts accept this — a synced account's history is
    bank-owned and immutable (``409 account_not_manual`` otherwise). The new
    row is always ``booked`` with ``role=personal`` and
    ``key_strategy=manual``; there is no pending lifecycle without a bank.

    Attributes
    ----------
    account_id : UUID
        The manual account the movement belongs to. Must belong to the caller
        and be manual.
    amount : int
        Signed value in the currency's minor unit (cents): negative for money
        out, positive for money in. A :class:`~pydantic.StrictInt`, so a float
        is rejected rather than truncated — the same discipline as
        :class:`~traccio.domain.money.Money`.
    currency : str
        ISO 4217 code of ``amount`` (three uppercase letters).
    value_date : datetime
        When the movement affects the balance (timezone-aware). Used for every
        date-bounded query — ``booked_at`` is left ``None`` for a manual row,
        and ``coalesce(booked_at, value_date)`` then falls back to this.
    description : str
        Free-text description the user typed.
    confirmed_category_id : UUID or None
        An optional category to confirm on the new row at creation time. Must
        belong to the caller. Equivalent to creating the row and then calling
        ``POST /transactions/{id}/category``.
    """

    account_id: UUID
    amount: StrictInt
    currency: CurrencyCode
    value_date: datetime
    description: str
    confirmed_category_id: UUID | None = None


class EditManualTransactionRequest(BaseModel):
    """Body for editing a movement on a manual account (ADR 0020).

    The same movement fields as :class:`CreateManualTransactionRequest` minus
    ``account_id`` (a movement does not move between accounts) and the category
    (``POST``/``DELETE /transactions/{id}/category`` own that). ``409
    transaction_not_manual`` if the row is on a synced account.

    Attributes
    ----------
    amount : int
        New signed value in minor units.
    currency : str
        New ISO 4217 code of ``amount``.
    value_date : datetime
        New value date (timezone-aware).
    description : str
        New description text.
    """

    amount: StrictInt
    currency: CurrencyCode
    value_date: datetime
    description: str


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
    event_id : UUID or None
        The event this transaction is currently grouped under, or ``None``.
        A display join, not a domain derivation: ``event_id`` lives only on
        the DB row (``db/models.py::TransactionRow``), deliberately absent
        from the domain ``Transaction`` (see ``docs/domain.md`` §Event), so
        the caller (``api/routers/transactions.py``) resolves it separately
        and passes it in — the same pattern the dashboard category breakdown
        uses to resolve a category name.
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
    event_id: UUID | None = None

    @classmethod
    def from_domain(
        cls,
        transaction: Transaction,
        *,
        advance_own_share: Money | None = None,
        event_id: UUID | None = None,
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
        event_id : UUID or None, optional
            The transaction's current event membership, if any. Not derived
            here — it isn't on the domain model — the caller resolves it
            (``db/repositories.py::get_transaction_event_id`` or
            ``event_ids_for_transactions``) and passes it in.

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
            event_id=event_id,
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
