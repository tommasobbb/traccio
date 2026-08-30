"""File import: turn a spreadsheet/CSV of an unconnectable feed into movements.

See ADR 0023. ``profiles`` describes a source's layout as data; ``parse``
turns decoded rows into :class:`~traccio.domain.imports.models.ParsedImport`
purely; the service (:mod:`traccio.services.imports`) reads the bytes.
"""

from traccio.domain.imports.models import (
    ImportRowError,
    ParsedImport,
    ParsedMovement,
)
from traccio.domain.imports.parse import parse_import
from traccio.domain.imports.profiles import PROFILES, ImportProfile, SplitRule

__all__ = [
    "PROFILES",
    "ImportProfile",
    "ImportRowError",
    "ParsedImport",
    "ParsedMovement",
    "SplitRule",
    "parse_import",
]
