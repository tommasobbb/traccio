"""Shared pytest fixtures and helpers for the backend test suite.

``sqlite_engine`` was, before this file existed, defined independently in 25
test modules under the name ``_engine`` or ``_sqlite_engine`` — the exact same
five lines every time (an in-memory SQLite engine on ``StaticPool``, so every
connection drawn from it shares the one in-memory database, plus
``Base.metadata.create_all``). Each test file still calls its own
locally-named wrapper the same way it always has; only the duplicated body
moved here.
"""

from sqlalchemy import Engine, create_engine
from sqlalchemy.pool import StaticPool

from traccio.db.base import Base


def sqlite_engine() -> Engine:
    """Create a fresh in-memory SQLite engine, schema already created.

    ``StaticPool`` is what makes this usable at all for an in-memory SQLite
    database: without it, every checkout from the pool would be a distinct,
    empty ``:memory:`` database, since SQLite's in-memory mode is per
    connection. ``check_same_thread=False`` allows the ``TestClient``'s
    request thread to share the connection this engine was built on.

    Returns
    -------
    Engine
        A SQLAlchemy engine with every table already created.
    """
    engine = create_engine(
        "sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool
    )
    Base.metadata.create_all(engine)
    return engine
