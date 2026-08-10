"""Resolve the running application version.

Kept out of ``main.py`` so both the app factory (for ``FastAPI(version=...)``)
and the health router can read the same value without importing the factory.
"""

from functools import lru_cache
from importlib.metadata import PackageNotFoundError, version


@lru_cache
def resolve_version() -> str:
    """Return the installed package version.

    Reads the version from installed package metadata rather than hardcoding
    it, so the running app and the distribution never disagree.

    Returns
    -------
    str
        The installed ``traccio`` version, or ``"0.0.0"`` when the package is
        not installed (e.g. an editable tree without metadata).
    """
    try:
        return version("traccio")
    except PackageNotFoundError:
        return "0.0.0"
