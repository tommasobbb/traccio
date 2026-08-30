"""Tests for ``domain/tracking.py::suggest_tracking_start`` (ADR 0024).

Pure: no database, no clock. Synthetic account ids and dates.
"""

from datetime import date
from uuid import uuid4

from traccio.domain.tracking import suggest_tracking_start


def test_no_accounts_has_no_suggestion() -> None:
    assert suggest_tracking_start({}) is None


def test_a_mid_month_start_suggests_the_first_of_the_next_month() -> None:
    assert suggest_tracking_start({uuid4(): date(2026, 6, 15)}) == date(2026, 7, 1)


def test_a_first_of_month_start_suggests_that_same_month() -> None:
    # The whole month is already covered — no need to skip it.
    assert suggest_tracking_start({uuid4(): date(2026, 6, 1)}) == date(2026, 6, 1)


def test_the_latest_starting_account_is_the_constraint() -> None:
    earliest = {
        uuid4(): date(2026, 3, 1),
        uuid4(): date(2026, 6, 15),
        uuid4(): date(2026, 1, 20),
    }
    assert suggest_tracking_start(earliest) == date(2026, 7, 1)


def test_all_accounts_starting_on_the_first_suggests_the_latest_such_month() -> None:
    earliest = {uuid4(): date(2026, 3, 1), uuid4(): date(2026, 6, 1)}
    assert suggest_tracking_start(earliest) == date(2026, 6, 1)


def test_a_december_start_rolls_into_january_of_the_next_year() -> None:
    assert suggest_tracking_start({uuid4(): date(2026, 12, 9)}) == date(2027, 1, 1)
