"""Shared FastAPI dependencies for the API layer.

Route handlers live in per-resource modules under ``routers/`` and so cannot
close over request-scoped values the way the old single-file factory did; the
dependencies they share are declared here instead.
"""

from uuid import UUID

from traccio.core.config import get_settings


def current_user_id() -> UUID:
    """Return the id of the user the current request is scoped to.

    Traccio is a single-user service until real auth lands (blocked on the M4
    decision), so this resolves to ``Settings.dev_user_id``. Every query stays
    written ``scoped by user_id``; when auth arrives, only this one function
    changes — the routers keep depending on it unchanged.

    Returns
    -------
    UUID
        The current user's id.
    """
    return get_settings().dev_user_id
