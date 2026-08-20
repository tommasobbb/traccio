"""Request and response schemas for the connections endpoints.

None of these carry secret material: the consent secret (``session_id``) is
encrypted at rest and never returned by any endpoint (``.claude/rules/data-safety.md``).
"""

from uuid import UUID

from pydantic import BaseModel


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
