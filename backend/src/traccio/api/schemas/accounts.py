"""Request and response schemas for the accounts endpoints."""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.accounts import display_name
from traccio.domain.enums import AccountIcon, AccountKind, PaletteColor
from traccio.domain.models import Account


class RenameAccountRequest(BaseModel):
    """Body for setting or clearing an account's alias.

    Attributes
    ----------
    alias : str or None
        The new alias, stripped and validated by
        :func:`~traccio.domain.accounts.normalize_account_alias`. ``None``
        clears the alias and falls back to the provider name — a mandatory,
        nullable field rather than an optional one, so "absent" and "clear
        it" are never ambiguous.
    """

    alias: str | None


class SetAccountAppearanceRequest(BaseModel):
    """Body for setting an account's colour and icon.

    A full replace, not a partial update — both fields are mandatory (but
    individually nullable, to allow clearing) — mirroring
    ``appearance``'s single action-style endpoint rather than two.

    Attributes
    ----------
    color : PaletteColor or None
        The new colour, or ``None`` to clear it.
    icon : AccountIcon or None
        The new icon, or ``None`` to clear it.
    """

    color: PaletteColor | None
    icon: AccountIcon | None


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
        ``current``, ``savings``, ``card``, or ``wallet``.
    currency : str
        The account's ISO 4217 currency.
    name : str or None
        Provider-supplied display name (overwritten on every sync).
    alias : str or None
        User-chosen display name (ADR 0017), or ``None`` if unset.
    display_name : str or None
        The one name the client should actually show — ``alias`` if set, else
        ``name``, else ``None`` — resolved once by
        :func:`~traccio.domain.accounts.display_name` so the client does not
        reimplement the fallback (it previously did, inconsistently, in three
        different places).
    color : PaletteColor or None
        User-chosen colour, or ``None`` if unset.
    icon : AccountIcon or None
        User-chosen icon, or ``None`` if unset.
    created_at : datetime
        When the account was first recorded.
    """

    id: UUID
    connection_id: UUID
    kind: AccountKind
    currency: str
    name: str | None
    alias: str | None
    display_name: str | None
    color: PaletteColor | None
    icon: AccountIcon | None
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
            alias=account.alias,
            display_name=display_name(account),
            color=account.color,
            icon=account.icon,
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
