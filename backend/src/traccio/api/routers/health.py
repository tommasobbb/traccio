"""Health endpoint router."""

from fastapi import APIRouter

from traccio.api.schemas.health import HealthResponse
from traccio.api.version import resolve_version

router = APIRouter()


@router.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    """Report liveness and the running version.

    Returns
    -------
    HealthResponse
        ``status="ok"`` and the current application version.
    """
    return HealthResponse(status="ok", version=resolve_version())
