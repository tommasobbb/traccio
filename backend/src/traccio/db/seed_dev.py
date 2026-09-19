"""Seed a development database with the single dev user and a few accounts.

For local use only: it gives ``GET /accounts`` something to return before real
bank data exists (M1). Idempotent — rows have fixed ids and are merged, so
re-running changes nothing. All values are synthetic (see
``docs/engineering.md``); this never touches a real bank response.

Run with ``make seed-dev`` (needs a reachable database). ``seed_demo.py``
(``make demo``) builds a full presentable dataset on top of the same user,
connection, and accounts this module creates — its ids are public for that
reason, not just this module's own use.
"""

from datetime import UTC, datetime
from uuid import UUID

from traccio.core.config import get_settings
from traccio.core.logging import get_logger
from traccio.db.models import AccountRow, ConnectionRow, UserRow
from traccio.db.repositories import seed_default_categories
from traccio.db.session import session_scope
from traccio.domain.enums import AccountKind, ConnectionStatus

logger = get_logger(__name__)

# Fixed ids so re-seeding merges instead of inserting duplicates.
CONNECTION_ID = UUID("00000000-0000-0000-0000-0000000000c1")
ACCOUNT_CURRENT_ID = UUID("00000000-0000-0000-0000-0000000000a1")
ACCOUNT_SAVINGS_ID = UUID("00000000-0000-0000-0000-0000000000a2")


def seed_dev() -> None:
    """Insert (or refresh) the dev user, one connection, and two accounts."""
    settings = get_settings()
    user_id = settings.dev_user_id
    now = datetime.now(UTC)

    with session_scope() as session:
        session.merge(UserRow(id=user_id, created_at=now))
        session.merge(
            ConnectionRow(
                id=CONNECTION_ID,
                user_id=user_id,
                provider="dev_seed",
                institution_name="TEST BANK 01",
                status=ConnectionStatus.ACTIVE,
                expires_at=None,
                created_at=now,
            )
        )
        session.merge(
            AccountRow(
                id=ACCOUNT_CURRENT_ID,
                user_id=user_id,
                connection_id=CONNECTION_ID,
                kind=AccountKind.CURRENT,
                currency="EUR",
                identification_hash="dev-acct-current-01",
                name="TEST CURRENT 01",
                created_at=now,
            )
        )
        session.merge(
            AccountRow(
                id=ACCOUNT_SAVINGS_ID,
                user_id=user_id,
                connection_id=CONNECTION_ID,
                kind=AccountKind.SAVINGS,
                currency="EUR",
                identification_hash="dev-acct-savings-01",
                name="TEST SAVINGS 01",
                created_at=now,
            )
        )
        created_categories = seed_default_categories(session, user_id=user_id)

    logger.info("seed_dev.done", accounts=2, categories_created=len(created_categories))


if __name__ == "__main__":
    seed_dev()
