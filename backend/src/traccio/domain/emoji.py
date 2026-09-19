"""Validating a user-supplied emoji.

An :class:`~traccio.domain.models.Event` carries an optional ``emoji`` for
visual identity (ADR 0027). Unlike a colour or an icon, which are closed
vocabularies (ADR 0017), the emoji is free text — an emoji renders itself, so
it needs no dark-mode asset and no client-side name mapping. It still must be
*one* emoji and not a caption or a string of them, so this module holds the
one pure check.

Grapheme-cluster segmentation is not in the standard library, so this is a
deliberate approximation: count the emoji "bases" that are not glued to a
previous one by a zero-width joiner, treat a run of regional indicators as a
single flag, and require exactly one such cluster. Good enough to tell "🎂"
from "🎉🎂" and from "birthday"; not a full Unicode oracle.

Imports nothing outside the standard library.
"""

import unicodedata

# A single emoji may still be several code points: a base pictograph plus skin
# tone modifier(s), variation selector(s), and zero-width joiners (a family or
# profession sequence). Eight is comfortably above every standard sequence and
# far short of "a sentence".
_MAX_CODE_POINTS = 8

_ZWJ = "‍"
_VARIATION_SELECTORS = {"︎", "️"}
_SKIN_TONE_MODIFIERS = range(0x1F3FB, 0x1F400)
_REGIONAL_INDICATORS = range(0x1F1E6, 0x1F200)


def _is_emoji_base(ch: str) -> bool:
    """Whether one code point can stand alone as an emoji (not a modifier)."""
    code = ord(ch)
    if code in _SKIN_TONE_MODIFIERS or code in _REGIONAL_INDICATORS:
        return False
    if code >= 0x1F000:  # supplementary-plane pictographs, symbols, dingbats
        return True
    if 0x2190 <= code <= 0x2BFF:  # BMP arrows, misc symbols, dingbats
        return True
    return unicodedata.category(ch) in {"So", "Sk"}


class InvalidEmojiError(ValueError):
    """The supplied value is not a single emoji.

    Carries a stable, value-free message (``docs/engineering.md``):
    the rejected text is never echoed back.
    """

    def __init__(self) -> None:
        super().__init__("value is not a single emoji")


def validate_emoji(value: str) -> str:
    """Return the trimmed emoji, or raise :class:`InvalidEmojiError`.

    Accepts exactly one emoji — including a joined sequence (skin tone, ZWJ
    family, variation selector) and a two-character regional-indicator flag.
    Rejects an empty string, an ASCII letter/digit or whitespace anywhere in
    it, more than :data:`_MAX_CODE_POINTS` code points, more than one emoji
    cluster, and a value with no emoji in it at all.

    Parameters
    ----------
    value : str
        The raw user input.

    Returns
    -------
    str
        ``value`` with surrounding whitespace stripped.

    Raises
    ------
    InvalidEmojiError
        If ``value`` is not a single emoji.
    """
    trimmed = value.strip()
    if not trimmed or len(trimmed) > _MAX_CODE_POINTS:
        raise InvalidEmojiError
    if any(ch.isascii() and (ch.isalnum() or ch.isspace()) for ch in trimmed):
        raise InvalidEmojiError

    clusters = 0
    prev_was_glue = False
    prev_was_regional = False
    for ch in trimmed:
        code = ord(ch)
        if ch == _ZWJ or ch in _VARIATION_SELECTORS:
            prev_was_glue = True
            prev_was_regional = False
            continue
        if code in _REGIONAL_INDICATORS:
            if not prev_was_regional:
                clusters += 1  # first half of a flag pair
            prev_was_regional = not prev_was_regional
            prev_was_glue = False
            continue
        if code in _SKIN_TONE_MODIFIERS or unicodedata.category(ch).startswith("M"):
            # A modifier or combining mark rides on the preceding base.
            prev_was_glue = False
            prev_was_regional = False
            continue
        if _is_emoji_base(ch):
            if not prev_was_glue:
                clusters += 1
            prev_was_glue = False
            prev_was_regional = False
            continue
        raise InvalidEmojiError

    if clusters != 1:
        raise InvalidEmojiError
    return trimmed
