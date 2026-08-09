"""Declarative base for the persistence layer.

``db/`` maps the pure domain entities to relational tables. It imports only
``domain`` (see ``docs/architecture.md``): nothing here reaches up into
``services/`` or ``api/``.

The shared :class:`Base` carries a naming convention so that indexes and
constraints get deterministic names. Stable names keep Alembic autogenerate
diffs empty across runs and make migrations reviewable.
"""

from sqlalchemy import MetaData
from sqlalchemy.orm import DeclarativeBase

# Deterministic names for every generated index and constraint. Without this,
# unnamed constraints get backend-specific auto names and autogenerate produces
# spurious diffs.
NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    """Declarative base shared by every ORM table.

    Attributes
    ----------
    metadata : MetaData
        Table registry carrying :data:`NAMING_CONVENTION`, used as Alembic's
        ``target_metadata``.
    """

    metadata = MetaData(naming_convention=NAMING_CONVENTION)
