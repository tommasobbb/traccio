"""Tests for ``domain/emoji.py::validate_emoji`` (ADR 0027).

Pure: no database, no network. The point of the check is to admit a single
emoji (including joined sequences and flags) and reject a caption or plain
text — not to be a perfect Unicode emoji oracle.
"""

import pytest

from traccio.domain.emoji import InvalidEmojiError, validate_emoji


@pytest.mark.parametrize(
    "value",
    [
        "🇹🇷",  # regional-indicator flag
        "✈️",  # dingbat + variation selector
        "🏠",  # supplementary-plane pictograph
        "🎉",
        "👨‍👩‍👧",  # ZWJ family sequence
        "👍🏽",  # skin-tone modifier
        "  🎂  ",  # surrounding whitespace is trimmed
    ],
)
def test_accepts_a_single_emoji(value: str) -> None:
    assert validate_emoji(value) == value.strip()


@pytest.mark.parametrize(
    "value",
    [
        "",
        "   ",
        "trip",  # plain word
        "a",
        "2026",
        "🎉 party",  # emoji plus text
        "🎉🎂",  # two separate emoji
        "🎉🎂🎈🎁🎀🎊🥳🍾🕯️",  # far too long
        ".",
        "-",
    ],
)
def test_rejects_non_emoji(value: str) -> None:
    with pytest.raises(InvalidEmojiError):
        validate_emoji(value)
