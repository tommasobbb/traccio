"""Match a file's header row to a profile's canonical column names (ADR 0023).

A profile (:mod:`traccio.domain.imports.profiles`) names its columns by short
canonical strings — ``"ID"``, ``"Disponibilità"``. A real export is looser: the
Satispay ``.xlsx`` labels the id column
``"ID (Comunicalo all'Assistenza Clienti in caso di problemi)"``, and another
exporter of the same feed might change the case, the spacing, or the Unicode
normalisation of an accented header. :func:`resolve_columns` bridges the two so
the profile constants stay readable and the parser
(:mod:`traccio.domain.imports.parse`) keeps looking columns up by their
canonical name.

Matching is deliberately conservative: an exact (normalised) match first for
every name, then a unique word-boundary prefix match for whatever is left. An
ambiguous prefix resolves to nothing and the column is reported missing —
guessing the wrong column on financial data is worse than a clear ``422``.

This module imports nothing outside ``domain/``.
"""

import re
import unicodedata
from collections.abc import Mapping, Sequence
from typing import NamedTuple

from traccio.domain.imports.profiles import ImportProfile

# A normalised header matches a canonical name by prefix only if the very next
# character is a non-word one — so ``"ID"`` claims ``"id (comunicalo…)"`` but
# never ``"identificativo"``.
_WORD_CHAR = re.compile(r"\w", re.UNICODE)
_WHITESPACE_RUN = re.compile(r"\s+", re.UNICODE)


def normalize_header(text: str) -> str:
    """Fold a header cell to the form matches are compared in.

    NFC-normalises (so a decomposed ``à`` compares equal to a composed one),
    collapses every run of whitespace — no-break spaces included, via ``\\s`` on
    the NFC text — to a single space, strips the ends, and casefolds.

    Parameters
    ----------
    text : str
        A raw header cell, already trimmed by the decoder.

    Returns
    -------
    str
        The normalised form, e.g. ``"Disponibilità "`` -> ``"disponibilità"``.
    """
    nfc = unicodedata.normalize("NFC", text)
    return _WHITESPACE_RUN.sub(" ", nfc).strip().casefold()


class ColumnResolution(NamedTuple):
    """The outcome of matching a header row to a profile.

    Attributes
    ----------
    columns : dict[str, str]
        Canonical name -> the actual header string in the file. Only resolved
        names appear.
    missing : tuple[str, ...]
        The profile's ``required_headers`` that no column could be matched to,
        in declaration order.
    """

    columns: dict[str, str]
    missing: tuple[str, ...]


def _wanted_names(profile: ImportProfile) -> list[str]:
    """Every canonical name the profile refers to, deduplicated, in a stable
    order: ``required_headers`` first, then any extra referenced column."""
    ordered = [
        *profile.required_headers,
        profile.date_column,
        profile.description_column,
        profile.id_column,
        profile.status_column,
        profile.amount_column,
    ]
    if profile.split is not None:
        ordered += [
            profile.split.total_column,
            profile.split.primary_column,
            profile.split.voucher_column,
        ]
    seen: dict[str, None] = {}
    for name in ordered:
        if name is not None and name not in seen:
            seen[name] = None
    return list(seen)


def _prefix_candidates(canonical: str, available: Mapping[str, str]) -> list[str]:
    """Header strings in ``available`` (normalised -> raw) that start with
    ``canonical`` at a word boundary."""
    hits: list[str] = []
    for norm, raw in available.items():
        rest = norm[len(canonical) :]
        if norm.startswith(canonical) and (rest == "" or not _WORD_CHAR.match(rest)):
            hits.append(raw)
    return hits


def resolve_columns(header: Sequence[str], *, profile: ImportProfile) -> ColumnResolution:
    """Match ``header`` to ``profile``'s canonical column names.

    Two passes, and the order matters. First every canonical name that equals a
    header exactly (after :func:`normalize_header`) claims it — done for all
    names up front so ``"Disponibilità"`` takes its own column before
    ``"Disponibilità dopo la transazione"`` can be considered. Then each still
    unresolved name takes the one remaining header it is a word-boundary prefix
    of, **only if that header is unique**; zero or several leaves the name
    unresolved.

    Parameters
    ----------
    header : Sequence[str]
        The file's header cells, already trimmed by the decoder.
    profile : ImportProfile
        The layout whose canonical names are being resolved.

    Returns
    -------
    ColumnResolution
        ``columns`` maps every resolved canonical name to its real header
        string; ``missing`` lists the ``required_headers`` left unresolved.
    """
    # normalised header -> first raw header with that form (a duplicate column
    # is ignored; the file is malformed and the parser would pick one anyway).
    normalized: dict[str, str] = {}
    for raw in header:
        norm = normalize_header(raw)
        normalized.setdefault(norm, raw)

    wanted = _wanted_names(profile)
    normalized_wanted = {name: normalize_header(name) for name in wanted}

    resolved: dict[str, str] = {}
    claimed: set[str] = set()

    for name in wanted:
        norm = normalized_wanted[name]
        if norm in normalized:
            resolved[name] = normalized[norm]
            claimed.add(normalized[norm])

    for name in wanted:
        if name in resolved:
            continue
        available = {norm: raw for norm, raw in normalized.items() if raw not in claimed}
        candidates = _prefix_candidates(normalized_wanted[name], available)
        if len(candidates) == 1:
            resolved[name] = candidates[0]
            claimed.add(candidates[0])

    missing = tuple(name for name in profile.required_headers if name not in resolved)
    return ColumnResolution(columns=resolved, missing=missing)


def remap_rows(
    rows: Sequence[Mapping[str, object]], columns: Mapping[str, str]
) -> list[dict[str, object]]:
    """Rewrite each row to be keyed by canonical name.

    ``columns`` is a :class:`ColumnResolution`'s ``columns`` — canonical name ->
    real header. The result keeps only the canonical keys, so the parser can go
    on calling ``row.get("ID")`` unchanged.

    Parameters
    ----------
    rows : Sequence[Mapping[str, object]]
        The decoded rows, keyed by the file's real headers.
    columns : Mapping[str, str]
        Canonical name -> real header, from :func:`resolve_columns`.

    Returns
    -------
    list[dict[str, object]]
        One dict per row, keyed by canonical name; a resolved column absent from
        a given row maps to ``None``.
    """
    return [{name: row.get(real) for name, real in columns.items()} for row in rows]
