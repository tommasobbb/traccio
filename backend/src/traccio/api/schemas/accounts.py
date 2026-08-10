"""Response schemas for the accounts endpoints."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.enums import AccountKind
from traccio.domain.models import Account


class AccountResponse(BaseModel):
    """One account as returned to the client.

    A deliberately narrow projection of :class:`~traccio.domain.models.Account`:
    ``user_id`` (implied by the caller) and ``identification_hash`` (an internal
    matching detail) are intentionally omitted.

    Attributes
    ----------
    id : UUID
        Stable account identifier.
    connection_id : UUID
        Connection currently exposing this account.
    kind : AccountKind
        ``current``, ``savings``, or ``card``.
    currency : str
        The account's ISO 4217 currency.
    name : str or None
        Optional display name.
    created_at : datetime
        When the account was first recorded.
    """

    id: UUID
    connection_id: UUID
    kind: AccountKind
    currency: str
    name: str | None
    created_at: datetime

    @classmethod
    def from_domain(cls, account: Account) -> "AccountResponse":
        """Project a domain :class:`~traccio.domain.models.Account`.

        Keeps the client projection next to the schema it produces rather than
        inline in the route handler, so the omitted fields (``user_id``,
        ``identification_hash``) are decided in one place.

        Parameters
        ----------
        account : Account
            The domain account to project.

        Returns
        -------
        AccountResponse
            The narrowed, client-facing view of ``account``.
        """
        return cls(
            id=account.id,
            connection_id=account.connection_id,
            kind=account.kind,
            currency=account.currency,
            name=account.name,
            created_at=account.created_at,
        )


class AccountsResponse(BaseModel):
    """Envelope for the account list.

    A wrapper object rather than a bare array leaves room for pagination or
    metadata later without breaking the generated Swift client.

    Attributes
    ----------
    accounts : list[AccountResponse]
        The caller's accounts, oldest first.
    """

    accounts: list[AccountResponse]
