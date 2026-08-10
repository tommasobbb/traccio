"""Response schema for the health endpoint."""

from pydantic import BaseModel


class HealthResponse(BaseModel):
    """Payload returned by the health endpoint.

    Attributes
    ----------
    status : str
        Liveness marker; ``"ok"`` when the app is serving.
    version : str
        The running application version (see
        :func:`~traccio.api.version.resolve_version`).
    """

    status: str
    version: str
