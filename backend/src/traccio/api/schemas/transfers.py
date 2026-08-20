"""Request and response schemas for the transfer endpoints.

A *suggestion* is a proposed link between two transactions the user may confirm;
nothing is written until they act (detection never mutates — see
``docs/architecture.md``). Confirming persists a
:class:`~traccio.domain.models.Transfer` and sets both legs' role; rejecting
records a dismissal so the pair is not suggested again. These schemas project the
pure-detection value object
:class:`~traccio.services.transfers.TransferSuggestion` and the domain
:class:`~traccio.domain.models.Transfer` to the wire.
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.models import Transfer
from traccio.services.transfers import TransferSuggestion


class TransferSuggestionResponse(BaseModel):
    """One suggested transfer as returned to the client.

    Mirrors :class:`~traccio.services.transfers.TransferSuggestion`. Amounts are
    integer minor units (cents); the two legs share ``currency``.

    Attributes
    ----------
    outgoing_transaction_id : UUID
        The negative leg (money left an account).
    incoming_transaction_id : UUID
        The positive leg (money arrived in another account).
    currency : str
        ISO 4217 code shared by both legs.
    outgoing_amount : int
        The outgoing leg's amount in minor units (negative).
    incoming_amount : int
        The incoming leg's amount in minor units (positive).
    amount_delta : int
        Absolute difference between the legs' magnitudes (``>= 0``); a small
        non-zero value is a fee or rounding.
    day_gap : int
        Whole days between the legs' effective dates (``>= 0``).
    """

    outgoing_transaction_id: UUID
    incoming_transaction_id: UUID
    currency: str
    outgoing_amount: int
    incoming_amount: int
    amount_delta: int
    day_gap: int

    @classmethod
    def from_domain(cls, suggestion: TransferSuggestion) -> "TransferSuggestionResponse":
        """Project a :class:`~traccio.services.transfers.TransferSuggestion`.

        Parameters
        ----------
        suggestion : TransferSuggestion
            The detected suggestion to project.

        Returns
        -------
        TransferSuggestionResponse
            The client-facing view of ``suggestion``.
        """
        return cls(
            outgoing_transaction_id=suggestion.outgoing_transaction_id,
            incoming_transaction_id=suggestion.incoming_transaction_id,
            currency=suggestion.currency,
            outgoing_amount=suggestion.outgoing_amount,
            incoming_amount=suggestion.incoming_amount,
            amount_delta=suggestion.amount_delta,
            day_gap=suggestion.day_gap,
        )


class TransferSuggestionsResponse(BaseModel):
    """Envelope for the transfer-suggestions list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    suggestions : list[TransferSuggestionResponse]
        The suggested transfers, most confident first.
    """

    suggestions: list[TransferSuggestionResponse]


class ConfirmTransferRequest(BaseModel):
    """Body for confirming a suggestion as a transfer.

    Names the two legs by role: the outgoing (negative) leg left one account and
    the incoming (positive) leg arrived in another. Both must belong to the
    caller.

    Attributes
    ----------
    outgoing_transaction_id : UUID
        The negative leg (money left an account).
    incoming_transaction_id : UUID
        The positive leg (money arrived in another account).
    """

    outgoing_transaction_id: UUID
    incoming_transaction_id: UUID


class RejectTransferRequest(BaseModel):
    """Body for rejecting a suggested pair as a transfer.

    The pair is order-independent — it is stored canonically so the same two
    transactions are not suggested again regardless of which was outgoing. Both
    must belong to the caller.

    Attributes
    ----------
    outgoing_transaction_id : UUID
        One leg of the rejected pair (the suggestion's outgoing leg).
    incoming_transaction_id : UUID
        The other leg of the rejected pair (the suggestion's incoming leg).
    """

    outgoing_transaction_id: UUID
    incoming_transaction_id: UUID


class TransferResponse(BaseModel):
    """One confirmed transfer as returned to the client.

    Projects :class:`~traccio.domain.models.Transfer`. Both legs already carry
    ``role=transfer``, so their ``effective_amount`` is zero on
    ``GET /transactions``.

    Attributes
    ----------
    id : UUID
        Stable identifier of the transfer.
    outgoing_transaction_id : UUID
        The negative leg (money left an account).
    incoming_transaction_id : UUID
        The positive leg (money arrived in another account).
    created_at : datetime
        When the transfer was confirmed (timezone-aware, UTC).
    """

    id: UUID
    outgoing_transaction_id: UUID
    incoming_transaction_id: UUID
    created_at: datetime

    @classmethod
    def from_domain(cls, transfer: Transfer) -> "TransferResponse":
        """Project a domain :class:`~traccio.domain.models.Transfer`.

        Parameters
        ----------
        transfer : Transfer
            The domain transfer to project.

        Returns
        -------
        TransferResponse
            The client-facing view of ``transfer``.
        """
        return cls(
            id=transfer.id,
            outgoing_transaction_id=transfer.outgoing_transaction_id,
            incoming_transaction_id=transfer.incoming_transaction_id,
            created_at=transfer.created_at,
        )


class TransfersResponse(BaseModel):
    """Envelope for the confirmed-transfers list.

    A wrapper object rather than a bare array leaves room for metadata later
    without breaking the generated Swift client.

    Attributes
    ----------
    transfers : list[TransferResponse]
        The user's confirmed transfers, oldest first.
    """

    transfers: list[TransferResponse]
