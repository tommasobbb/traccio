"""ORM tables mapping the domain entities to relational storage.

One table per domain entity. Rows are named with a ``Row`` suffix to keep them
distinct from the pure :mod:`traccio.domain.models` types they persist; the
translation between the two lives in :mod:`traccio.db.mappers`, never in
``domain``.

Enums are stored as their string ``.value`` in a portable ``VARCHAR`` (no native
PostgreSQL enum type and no check constraint — ``_enum_column`` leaves
``create_constraint`` at its SQLAlchemy default of ``False``), so adding a member
never requires a type migration. The column width is still sized to the longest
current member at the time of the migration that adds it, so a *later* member
longer than that (e.g. ``rejected`` vs. the original ``pending``/``booked``) does
need a width-widening migration — see
``d1f4b6a29c73_widen_transaction_status.py`` for the one this bit already.

Schema-level invariants (see ``docs/architecture.md``):

- Every table carries ``user_id``; queries are always scoped by it.
- ``transactions`` is unique on ``(account_id, stable_key)``, which is what
  makes sync idempotent — a re-import cannot duplicate a row.

Split from one 848-line module into a submodule per domain concern
(2026-09-17), mirroring :mod:`traccio.db.repositories`. Every public name is
re-exported here, so existing ``from traccio.db.models import X`` imports are
unchanged.
"""

from traccio.db.models.accounts import AccountRow
from traccio.db.models.advances import AdvanceParticipantRow, AdvanceRow, ReimbursementRow
from traccio.db.models.categories import CategoryRow
from traccio.db.models.connections import ConnectionRow
from traccio.db.models.events import EventRow
from traccio.db.models.fx import FxRateRow
from traccio.db.models.rules import RuleRow
from traccio.db.models.settings import UserRow
from traccio.db.models.sync_runs import SyncRunRow
from traccio.db.models.transactions import TransactionRow
from traccio.db.models.transfers import TransferDismissalRow, TransferRow

__all__ = [
    "AccountRow",
    "AdvanceParticipantRow",
    "AdvanceRow",
    "CategoryRow",
    "ConnectionRow",
    "EventRow",
    "FxRateRow",
    "ReimbursementRow",
    "RuleRow",
    "SyncRunRow",
    "TransactionRow",
    "TransferDismissalRow",
    "TransferRow",
    "UserRow",
]
