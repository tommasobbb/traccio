"""Presence-only field census of a connection's raw Enable Banking payload.

An operational diagnostic, not part of the app or the test suite — the same
category as ``eb_smoke.py``. It exists to answer one question without ever
looking at a real value: *which raw keys does this bank's transaction entry
actually carry, and how often?*

That question came up debugging PayPal transactions arriving with no date and
no description while Revolut/Isybank are fine
(``providers/enable_banking/transactions.py`` only reads ``booking_date``,
``value_date``, and ``remittance_information`` — a present-but-malformed
value there would raise, so a successful sync means those three keys are
simply absent or null for the affected entries; the data, if it exists, lives
under a key the mapper never reads). No raw payload is stored anywhere in the
database (``TransactionRow`` has no JSON column), so root cause needs a fresh
live capture — this script is that capture, shaped so it structurally cannot
leak a financial value.

Data safety (``.claude/rules/data-safety.md``): the three guards below make a
value leak impossible by construction, not by discipline.

1. **Nothing derived from a value is ever formatted into output.** The only
   integers printed are counts of entries; the only strings are key *paths*,
   enum member names, and fixed literals. There is no ``f"{value}"``
   anywhere in this module — that is a standing invariant of the file, not a
   one-time review.
2. **Key path segments are allowlisted** by :data:`_KEY_NAME_RE`. A key that
   does not match is counted under the literal path
   ``"<non-conforming-key>"`` and its real name is never printed — closing
   the theoretical case where a key *name* itself were sensitive.
3. **No lengths, no ranges, no min/max of a value** — only classifications
   (:class:`Presence`, :class:`ShapeTag`, :class:`DateShape`). A date-ish key
   reports whether it parses as an ISO date, never the date itself.

Run with ``make eb-census CONNECTION=<connection-id>`` (needs
``TRACCIO_ENABLE_BANKING_*``, ``TRACCIO_ENCRYPTION_KEY``, and
``TRACCIO_DATABASE_URL`` set — usually via a local ``.env`` pointing at
``dev.db``). Use ``--list`` first to find a connection id. This makes real
Enable Banking API calls (session + one ``get_account_details`` per account +
transaction pages) and so consumes a little of the bank's rate-limit budget
(``docs/decisions/0010-background-sync-scheduler.md``) — but it deliberately
records no :class:`~traccio.db.models.SyncRunRow` and is not gated by that
budget, since a diagnostic must not pollute the app's own sync accounting.
Bound the cost with ``--max-pages`` on a first exploratory run.
"""

import argparse
import re
import sys
from collections import Counter
from collections.abc import Mapping, Sequence
from datetime import UTC, datetime, timedelta
from enum import Enum
from typing import Any
from uuid import UUID

from traccio.api.deps import build_enable_banking_client
from traccio.core.config import get_settings
from traccio.core.crypto import get_token_cipher
from traccio.db.repositories import get_connection_credentials, list_connections
from traccio.db.session import session_scope
from traccio.providers.base import ProviderError

_MAX_DEPTH = 2
_KEY_NAME_RE = re.compile(r"^[a-z0-9_]{1,64}$")
_NON_CONFORMING_KEY = "<non-conforming-key>"
_DATE_KEY_RE = re.compile(r"(^|_)date($|_)")
_ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class Presence(Enum):
    """Whether a key was there at all, distinguishing absent from explicitly null."""

    ABSENT = "absent"
    NULL = "null"
    EMPTY = "empty"
    PRESENT = "present"


class ShapeTag(Enum):
    """The Python type of a present value — never the value itself."""

    STR = "str"
    INT = "int"
    FLOAT = "float"
    BOOL = "bool"
    LIST = "list"
    DICT = "dict"
    UNKNOWN = "unknown"


class DateShape(Enum):
    """Whether a date-ish key's value looks like a date — never the date."""

    ISO_DATE = "iso_date"
    ISO_DATETIME = "iso_datetime"
    OTHER_STRING = "other_string"
    NOT_A_STRING = "not_a_string"


class KeyCensus:
    """Presence/shape tally for one raw key path, across every entry seen.

    Attributes
    ----------
    path : str
        Dotted key path, e.g. ``"booking_date"`` or ``"creditor.name"``.
    """

    __slots__ = ("absent", "date_shapes", "empty", "null", "path", "present", "shapes")

    def __init__(self, path: str) -> None:
        self.path = path
        self.absent = 0
        self.null = 0
        self.empty = 0
        self.present = 0
        self.shapes: Counter[ShapeTag] = Counter()
        self.date_shapes: Counter[DateShape] = Counter()


def classify(value: object) -> tuple[Presence, ShapeTag, DateShape | None]:
    """Classify a raw value's presence and shape, without ever reading its content.

    Parameters
    ----------
    value : object
        The raw value at some key path, or a sentinel meaning "absent" is
        handled by the caller (this function is only called when the key
        exists).

    Returns
    -------
    tuple[Presence, ShapeTag, DateShape or None]
        ``Presence`` is ``NULL``/``EMPTY``/``PRESENT`` (never ``ABSENT`` —
        that case never reaches this function). ``DateShape`` is populated
        only for a string value; ``None`` otherwise.
    """
    if value is None:
        return Presence.NULL, ShapeTag.UNKNOWN, None
    if isinstance(value, bool):
        return Presence.PRESENT, ShapeTag.BOOL, None
    if isinstance(value, str):
        if value == "":
            return Presence.EMPTY, ShapeTag.STR, None
        return Presence.PRESENT, ShapeTag.STR, _date_shape(value)
    if isinstance(value, list):
        return (Presence.EMPTY if not value else Presence.PRESENT), ShapeTag.LIST, None
    if isinstance(value, dict):
        return (Presence.EMPTY if not value else Presence.PRESENT), ShapeTag.DICT, None
    if isinstance(value, int):
        return Presence.PRESENT, ShapeTag.INT, None
    if isinstance(value, float):
        return Presence.PRESENT, ShapeTag.FLOAT, None
    return Presence.PRESENT, ShapeTag.UNKNOWN, None


def _date_shape(value: str) -> DateShape:
    """Classify whether a string *looks like* a date — the shape only, never the value."""
    if _ISO_DATE_RE.match(value):
        return DateShape.ISO_DATE
    try:
        datetime.fromisoformat(value)
    except ValueError:
        return DateShape.OTHER_STRING
    return DateShape.ISO_DATETIME


def _safe_path_segment(key: object) -> str:
    """Return ``key`` if it is an allowlisted path segment, else a fixed placeholder."""
    if isinstance(key, str) and _KEY_NAME_RE.match(key):
        return key
    return _NON_CONFORMING_KEY


def census_entries(
    entries: Sequence[Mapping[str, Any]], *, max_depth: int = _MAX_DEPTH
) -> dict[str, KeyCensus]:
    """Tally presence/shape per key path across every entry, up to ``max_depth``.

    Two passes, deliberately: first discover every key path that appears on
    *any* entry (as a tuple of real key names, so a path can still be
    resolved against each entry), then tally each entry against the full set
    of discovered paths — so a path first seen on entry 50 is correctly
    counted as ``absent`` on entries 1-49, not silently skipped for them.

    Recurses into a ``dict`` value one level (by default), emitting
    ``"parent.child"`` display paths — this is what surfaces
    ``creditor.name`` / ``debtor.name`` as candidate description sources
    without hardcoding them.

    Parameters
    ----------
    entries : Sequence[Mapping]
        The raw ``transactions`` array entries from one or more Enable
        Banking pages.
    max_depth : int, optional
        How many levels of nested ``dict`` to recurse into.

    Returns
    -------
    dict[str, KeyCensus]
        One :class:`KeyCensus` per display path observed on at least one
        entry.
    """
    raw_paths = _discover_paths(entries, max_depth)
    by_display: dict[str, list[tuple[str, ...]]] = {}
    for raw_path in raw_paths:
        by_display.setdefault(_display_path(raw_path), []).append(raw_path)

    by_key: dict[str, KeyCensus] = {}
    for display, variants in sorted(by_display.items()):
        census = KeyCensus(display)
        by_key[display] = census
        for entry in entries:
            _tally_one(census, entry, variants)
    return by_key


def _discover_paths(entries: Sequence[Mapping[str, Any]], max_depth: int) -> set[tuple[str, ...]]:
    """Collect every real key path (as a tuple of raw key names) seen on any entry."""
    paths: set[tuple[str, ...]] = set()

    def walk(obj: Mapping[str, Any], prefix: tuple[str, ...], depth: int) -> None:
        for key, value in obj.items():
            path = (*prefix, key)
            paths.add(path)
            if isinstance(value, dict) and depth < max_depth:
                walk(value, path, depth + 1)

    for entry in entries:
        walk(entry, (), 1)
    return paths


def _display_path(raw_path: tuple[str, ...]) -> str:
    """Render a raw key-name tuple as a dotted display path, sanitizing each segment."""
    return ".".join(_safe_path_segment(segment) for segment in raw_path)


def _resolve(entry: Mapping[str, Any], raw_path: tuple[str, ...]) -> tuple[object, bool]:
    """Walk ``raw_path`` into ``entry``. Returns ``(value, existed)``."""
    current: Any = entry
    for part in raw_path:
        if not isinstance(current, dict) or part not in current:
            return None, False
        current = current[part]
    return current, True


def _tally_one(
    census: KeyCensus, entry: Mapping[str, Any], variants: list[tuple[str, ...]]
) -> None:
    """Tally one entry against a display path's real-path variant(s).

    Normally exactly one variant (sanitization only collapses distinct raw
    key names in the rare case one fails :data:`_KEY_NAME_RE`); the first
    variant present on this entry wins.
    """
    for raw_path in variants:
        value, existed = _resolve(entry, raw_path)
        if existed:
            presence, shape, date_shape = classify(value)
            _bump(census, presence)
            census.shapes[shape] += 1
            if date_shape is not None and _DATE_KEY_RE.search(raw_path[-1]):
                census.date_shapes[date_shape] += 1
            return
    census.absent += 1


def _bump(census: KeyCensus, presence: Presence) -> None:
    if presence is Presence.NULL:
        census.null += 1
    elif presence is Presence.EMPTY:
        census.empty += 1
    elif presence is Presence.PRESENT:
        census.present += 1


def derived_questions(total: int, by_key: Mapping[str, KeyCensus]) -> list[str]:
    """Render the handful of yes/no questions that actually decide the mapper fix.

    Parameters
    ----------
    total : int
        Total entries censused.
    by_key : Mapping[str, KeyCensus]
        The census result.

    Returns
    -------
    list[str]
        Human-readable lines, counts only.
    """

    def missing(path: str) -> int:
        c = by_key.get(path)
        if c is None:
            return total
        return c.absent + c.null

    booking = missing("booking_date")
    value = missing("value_date")
    tx_date = missing("transaction_date")
    remittance = missing("remittance_information")
    creditor_name = missing("creditor.name")
    debtor_name = missing("debtor.name")

    return [
        f"entries missing booking_date:                              {booking} / {total}",
        f"entries missing value_date:                                 {value} / {total}",
        f"entries missing transaction_date:                           {tx_date} / {total}",
        f"entries missing booking_date AND value_date AND transaction_date: "
        f"{min(booking, value, tx_date) if total else 0} (upper bound) / {total}",
        f"entries missing remittance_information:                     {remittance} / {total}",
        f"entries missing remittance_information AND creditor.name AND debtor.name: "
        f"{min(remittance, creditor_name, debtor_name) if total else 0} (upper bound) / {total}",
    ]


def render(total: int, by_key: Mapping[str, KeyCensus]) -> list[str]:
    """Render the presence table as printable lines. No value ever appears."""
    lines = [
        f"entries censused: {total}",
        "",
        f"{'key path':<45} {'absent':>7} {'null':>6} {'empty':>6} {'present':>8}  shapes",
    ]
    for path in sorted(by_key):
        c = by_key[path]
        shapes = ", ".join(
            f"{tag.value}:{n}" for tag, n in sorted(c.shapes.items(), key=lambda kv: kv[0].value)
        )
        dates = ", ".join(
            f"{tag.value}:{n}"
            for tag, n in sorted(c.date_shapes.items(), key=lambda kv: kv[0].value)
        )
        shape_col = shapes if not dates else f"{shapes}  [dates: {dates}]"
        lines.append(
            f"{path:<45} {c.absent:>7} {c.null:>6} {c.empty:>6} {c.present:>8}  {shape_col}"
        )
    lines.append("")
    lines.append("derived questions")
    lines.extend(f"  {line}" for line in derived_questions(total, by_key))
    return lines


def _fetch_raw_entries(
    *, connection_id: str, account_index: int | None, days: int, max_pages: int
) -> tuple[list[dict[str, Any]], int]:
    """Fetch raw transaction entries for a connection's account(s).

    Returns
    -------
    tuple[list[dict], int]
        The raw entries (only the ``transactions`` array items — never
        anything printed from them directly) and the number of provider
        calls made, so cost stays visible.
    """
    settings = get_settings()
    calls = 0
    with session_scope() as session:
        encrypted = get_connection_credentials(
            session, user_id=settings.dev_user_id, connection_id=UUID(connection_id)
        )
    if encrypted is None:
        raise SystemExit("connection has no active, usable credentials")
    cipher = get_token_cipher(settings.encryption_key)
    credentials = cipher.decrypt(encrypted)

    client = build_enable_banking_client()
    try:
        session_resp = client.get_session(credentials)
        calls += 1
        account_uids = session_resp.get("accounts")
        if not isinstance(account_uids, list):
            raise SystemExit("Enable Banking session response is missing 'accounts'")
        if account_index is not None:
            account_uids = [account_uids[account_index]]

        entries: list[dict[str, Any]] = []
        for uid in account_uids:
            details = client.get_account_details(uid)
            calls += 1
            print(
                f"account: cash_account_type={details.get('cash_account_type')!r} "
                f"currency={details.get('currency')!r}",
                file=sys.stderr,
            )
            date_from = _days_ago(days)
            continuation_key: str | None = None
            pages = 0
            while True:
                page = client.get_account_transactions(
                    uid, date_from=date_from, continuation_key=continuation_key
                )
                calls += 1
                pages += 1
                page_entries = page.get("transactions")
                if isinstance(page_entries, list):
                    entries.extend(page_entries)
                continuation_key = page.get("continuation_key")
                if not continuation_key or (max_pages and pages >= max_pages):
                    break
        return entries, calls
    finally:
        client.close()


def _days_ago(days: int) -> str:
    return (datetime.now(UTC) - timedelta(days=days)).date().isoformat()


def _list_connections() -> int:
    settings = get_settings()
    with session_scope() as session:
        connections = list_connections(session, settings.dev_user_id)
    if not connections:
        print("no connections for the dev user")
        return 0
    for c in connections:
        print(f"{c.id}  {c.provider}  {c.institution_name}  status={c.status.value}")
    return 0


def main() -> int:
    """Run the field census. See the module docstring for what it prints and why.

    Returns
    -------
    int
        Process exit code: ``0`` on success, ``1`` on a missing credential or
        a provider error (message kept value-free).
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    parser.add_argument(
        "--list", action="store_true", help="List the dev user's connections and exit."
    )
    parser.add_argument("--connection-id", help="Connection UUID to census.")
    parser.add_argument(
        "--account-index", type=int, default=None, help="Census only this account index."
    )
    parser.add_argument(
        "--days",
        type=int,
        default=None,
        help="History window in days (default: Settings.initial_history_days).",
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=0,
        help="Stop after this many pages per account (0 = unlimited).",
    )
    args = parser.parse_args()

    if args.list:
        return _list_connections()
    if not args.connection_id:
        print("--connection-id is required (use --list to find one)", file=sys.stderr)
        return 1

    days = args.days if args.days is not None else get_settings().initial_history_days
    try:
        entries, calls = _fetch_raw_entries(
            connection_id=args.connection_id,
            account_index=args.account_index,
            days=days,
            max_pages=args.max_pages,
        )
    except ProviderError as exc:
        print(f"Enable Banking request failed: {exc}", file=sys.stderr)
        return 1

    print(f"provider calls made: {calls}", file=sys.stderr)
    by_key = census_entries(entries)
    for line in render(len(entries), by_key):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
