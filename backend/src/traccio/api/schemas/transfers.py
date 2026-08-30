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

from traccio.domain.enums import TransferKind
from traccio.domain.models import Transfer
from traccio.services.transfers import TransferSuggestion


class TransferSuggestionResponse(BaseModel):
    """One suggested transfer as returned to the client.

    Mirrors :class:`~traccio.services.transfers.TransferSuggestion`. Amounts are
    integer minor units (cents); the two legs share ``currency``.

    Attributes
    ----------
    kind : TransferKind
        ``two_sided`` (opposite-sign pair) or ``funded_payment`` (two outflows,
        the ``incoming`` leg on a wallet is the real purchase).
    outgoing_transaction_id : UUID
        Two-sided: the negative leg. Funded payment: the funding leg.
    incoming_transaction_id : UUID
        Two-sided: the positive leg. Funded payment: the funded (wallet) leg.
    currency : str
        ISO 4217 code shared by both legs.
    outgoing_amount : int
        The outgoing leg's amount in minor units (negative for both kinds).
    incoming_amount : int
        The incoming leg's amount in minor units (positive for a two-sided
        transfer, negative for a funded payment).
    amount_delta : int
        Absolute difference between the legs' magnitudes (``>= 0``); a small
        non-zero value is a fee or rounding.
    day_gap : int
        Whole days between the legs' effective dates (``>= 0``).
    """

    kind: TransferKind
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
            kind=suggestion.kind,
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

    ``kind`` decides the sign rule and which legs are zeroed:

    - ``two_sided`` (the default) — ``outgoing`` negative, ``incoming``
      positive; **both** legs become ``role=transfer``.
    - ``funded_payment`` — **both** legs are outflows; ``outgoing`` is the
      funding leg (set to ``role=funding``) and ``incoming`` is the funded leg,
      the real expense, left ``personal``.

    Both legs must belong to the caller.

    Attributes
    ----------
    kind : TransferKind
        Which pairing to confirm. Defaults to ``two_sided`` for compatibility
        with pre-existing clients.
    outgoing_transaction_id : UUID
        Two-sided: the negative leg. Funded payment: the funding leg.
    incoming_transaction_id : UUID
        Two-sided: the positive leg. Funded payment: the funded leg.
    """

    kind: TransferKind = TransferKind.TWO_SIDED
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

    Projects :class:`~traccio.domain.models.Transfer`. For a ``two_sided``
    transfer both legs carry ``role=transfer``; for a ``funded_payment`` only
    ``outgoing_transaction_id`` carries ``role=funding`` and
    ``incoming_transaction_id`` stays ``personal`` (the real expense). Either
    way the zeroed legs read ``effective_amount == 0`` on ``GET /transactions``.

    Attributes
    ----------
    id : UUID
        Stable identifier of the transfer.
    kind : TransferKind
        ``two_sided`` or ``funded_payment``.
    outgoing_transaction_id : UUID
        Two-sided: the negative leg. Funded payment: the funding leg
        (``role=funding``).
    incoming_transaction_id : UUID
        Two-sided: the positive leg. Funded payment: the funded leg, the real
        expense (left ``personal``).
    created_at : datetime
        When the transfer was confirmed (timezone-aware, UTC).
    """

    id: UUID
    kind: TransferKind
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
            kind=transfer.kind,
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
