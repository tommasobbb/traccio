"""Response schemas for the transfer-suggestions endpoint.

A suggestion is a *proposed* link between two transactions the user may confirm;
nothing is written until they do (detection never mutates — see
``docs/architecture.md``). This projects the pure-detection value object
:class:`~traccio.services.transfers.TransferSuggestion` to the wire.
"""

from uuid import UUID

from pydantic import BaseModel

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
