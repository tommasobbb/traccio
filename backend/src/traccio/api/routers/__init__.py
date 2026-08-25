"""HTTP routers for the API layer.

One ``APIRouter`` module per resource; ``create_app`` includes each of them.
This package re-exports the routers so the factory imports from one place.
"""

from traccio.api.routers.accounts import router as accounts_router
from traccio.api.routers.advances import router as advances_router
from traccio.api.routers.categories import router as categories_router
from traccio.api.routers.connections import callback_router as connections_callback_router
from traccio.api.routers.connections import router as connections_router
from traccio.api.routers.dashboard import router as dashboard_router
from traccio.api.routers.events import router as events_router
from traccio.api.routers.health import router as health_router
from traccio.api.routers.rules import router as rules_router
from traccio.api.routers.transactions import router as transactions_router
from traccio.api.routers.transfers import router as transfers_router

__all__ = [
    "accounts_router",
    "advances_router",
    "categories_router",
    "connections_callback_router",
    "connections_router",
    "dashboard_router",
    "events_router",
    "health_router",
    "rules_router",
    "transactions_router",
    "transfers_router",
]
