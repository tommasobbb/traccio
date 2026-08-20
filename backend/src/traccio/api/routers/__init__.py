"""HTTP routers for the API layer.

One ``APIRouter`` module per resource; ``create_app`` includes each of them.
This package re-exports the routers so the factory imports from one place.
"""

from traccio.api.routers.accounts import router as accounts_router
from traccio.api.routers.connections import router as connections_router
from traccio.api.routers.health import router as health_router
from traccio.api.routers.transactions import router as transactions_router
from traccio.api.routers.transfers import router as transfers_router

__all__ = [
    "accounts_router",
    "connections_router",
    "health_router",
    "transactions_router",
    "transfers_router",
]
