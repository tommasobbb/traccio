"""Alembic migrations must produce the schema the models declare.

Every other DB-backed test builds its schema with ``Base.metadata.create_all``
(fast, but it never runs a single migration file), while production runs the
24 real migrations end to end. Nothing else in the suite proves the two
agree — a forgotten column in a migration is invisible until a production
``UndefinedColumn`` at runtime. This runs ``alembic upgrade head`` against a
throwaway SQLite file and diffs the result against ``Base.metadata``.

Four migrations skip creating certain foreign keys on SQLite on purpose
(``if op.get_bind().dialect.name != "sqlite":`` — SQLite's own limited FK
support was never the target, Postgres is), so a diff of *only* foreign-key
adds is expected and tolerated here. Any other kind of diff — a missing or
extra table, column, index, unique constraint, or a type mismatch — fails
the test.
"""

from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from sqlalchemy import create_engine

import traccio.core.config as config_module
import traccio.db.models  # noqa: F401  (side-effect: registers tables on Base.metadata)
from traccio.db.base import Base

_BACKEND_ROOT = Path(__file__).resolve().parents[1]

# alembic's own diff-tuple shape: element 0 names the operation.
_FK_DIFF_KINDS = {"add_fk", "remove_fk"}


def test_migrations_produce_the_schema_the_models_declare(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    db_path = tmp_path / "alembic_check.db"
    sqlite_url = f"sqlite:///{db_path}"

    # alembic/env.py reads the database URL from get_settings() itself (not
    # from alembic.ini), so it targets the same database as the app — pointing
    # it at a scratch file means overriding get_settings, not alembic.ini.
    fake_settings = config_module.get_settings().model_copy(update={"database_url": sqlite_url})
    monkeypatch.setattr(config_module, "get_settings", lambda: fake_settings)

    # env.py calls logging.config.fileConfig(alembic.ini) before running
    # migrations, which reconfigures Python's *global* logging module (and,
    # with it, structlog's) as a side effect of running migrations
    # in-process — invisible in normal use (`alembic upgrade` always runs as
    # its own CLI process), but it would otherwise leak into every test that
    # runs after this one in the same session. env.py resolves fileConfig via
    # `from logging.config import fileConfig`, re-executed fresh on every
    # alembic invocation, so patching the attribute here is enough; nothing
    # else about how Config reads alembic.ini is affected.
    monkeypatch.setattr("logging.config.fileConfig", lambda *args: None)

    alembic_cfg = Config(str(_BACKEND_ROOT / "alembic.ini"))
    command.upgrade(alembic_cfg, "head")

    engine = create_engine(sqlite_url)
    try:
        with engine.connect() as connection:
            context = MigrationContext.configure(connection)
            diffs = compare_metadata(context, Base.metadata)
    finally:
        engine.dispose()

    unexpected = [diff for diff in diffs if diff[0] not in _FK_DIFF_KINDS]
    assert unexpected == [], (
        "alembic upgrade head does not produce the schema Base.metadata "
        f"declares (ignoring the known SQLite foreign-key omissions): {unexpected}"
    )
