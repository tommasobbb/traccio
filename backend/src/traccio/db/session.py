"""Engine and session factory for the persistence layer.

The database URL comes from :func:`traccio.core.config.get_settings` — the same
single source Alembic reads — so the application and its migrations never
disagree on which database they target. Synchronous SQLAlchemy 2.0 is used
deliberately: this is a single-user service with no need for async I/O.
"""

from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from traccio.core.config import get_settings

# One engine per process. Created lazily on import; the connection pool it holds
# is only opened on first use.
engine: Engine = create_engine(get_settings().database_url)

# ``expire_on_commit=False`` keeps mapped attributes readable after commit,
# which the mappers rely on when translating a just-persisted row back to a
# domain object.
SessionLocal = sessionmaker(engine, expire_on_commit=False)


@contextmanager
def session_scope() -> Iterator[Session]:
    """Provide a transactional session, committing or rolling back on exit.

    For scripts and background work. HTTP handlers use :func:`get_session`.

    Yields
    ------
    Session
        An active session. The block's work is committed on clean exit and
        rolled back if an exception propagates.
    """
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def get_session() -> Iterator[Session]:
    """Yield a session for a single request, as a FastAPI dependency.

    Tests override this in ``app.dependency_overrides`` to bind a different
    engine (e.g. SQLite), which is why the endpoints depend on it rather than
    touching :data:`SessionLocal` directly.

    Yields
    ------
    Session
        An active session, closed when the request completes.
    """
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()
