"""Request and response schemas for the connections endpoints.

None of these carry secret material: the consent secret (``session_id``) is
encrypted at rest and never returned by any endpoint (``.claude/rules/data-safety.md``).
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from traccio.domain.enums import ConnectionStatus
from traccio.domain.models import Connection


class StartConnectionRequest(BaseModel):
    """Request to begin authorizing a bank connection.

    Attributes
    ----------
    institution : str
        The bank's provider-scoped identifier (Enable Banking ASPSP ``name``).
    country : str
        ISO 3166-1 alpha-2 country of the bank.
    """

    institution: str
    country: str


class StartConnectionResponse(BaseModel):
    """The started authorization: where to send the user.

    Attributes
    ----------
    connection_id : UUID
        The pending connection created for this authorization.
    authorization_url : str
        The bank authorization URL to open in the system browser.
    """

    connection_id: UUID
    authorization_url: str


class SyncResponse(BaseModel):
    """The outcome of syncing a connection.

    Only counts are returned, never account or transaction contents
    (``.claude/rules/data-safety.md``); the data itself is read back via the
    resource endpoints (e.g. ``GET /accounts``).

    Attributes
    ----------
    accounts_synced : int
        How many accounts were discovered and persisted (inserted or updated).
    transactions_synced : int
        How many transactions were fetched and persisted across those accounts
        (inserted, or updated in place while still pending).
    """

    accounts_synced: int
    transactions_synced: int


class ConnectionResponse(BaseModel):
    """One connection as returned to the client.

    A narrow projection of :class:`~traccio.domain.models.Connection`. It
    carries no secret material by construction: the consent secret and the
    anti-CSRF ``auth_state`` live only on the ORM row, never on the domain model
    this is built from (see ``.claude/rules/data-safety.md``). ``user_id`` is
    implied by the caller and omitted.

    Attributes
    ----------
    id : UUID
        Stable connection identifier.
    provider : str
        Adapter that produced the connection (e.g. ``"enable_banking"``).
    institution_name : str
        Human-readable bank name for display.
    status : ConnectionStatus
        Consent lifecycle state.
    expires_at : datetime or None
        Consent expiry; ``None`` while pending. Surfacing an upcoming expiry is
        a product concern the client renders from this field.
    created_at : datetime
        When the connection was created.
    """

    id: UUID
    provider: str
    institution_name: str
    status: ConnectionStatus
    expires_at: datetime | None
    created_at: datetime

    @classmethod
    def from_domain(cls, connection: Connection) -> "ConnectionResponse":
        """Project a domain :class:`~traccio.domain.models.Connection`.

        Parameters
        ----------
        connection : Connection
            The domain connection to project.

        Returns
        -------
        ConnectionResponse
            The narrowed, client-facing view of ``connection``.
        """
        return cls(
            id=connection.id,
            provider=connection.provider,
            institution_name=connection.institution_name,
            status=connection.status,
            expires_at=connection.expires_at,
            created_at=connection.created_at,
        )


class ConnectionsResponse(BaseModel):
    """Envelope for the connection list.

    A wrapper object rather than a bare array leaves room for pagination or
    metadata later without breaking the generated Swift client.

    Attributes
    ----------
    connections : list[ConnectionResponse]
        The caller's connections, oldest first.
    """

    connections: list[ConnectionResponse]
