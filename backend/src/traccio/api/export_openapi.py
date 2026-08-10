"""Export the OpenAPI schema to a file.

Run via ``make openapi``, which writes ``docs/api/openapi.json`` — the schema
the Swift ``TraccioCore`` package decodes its models from. Kept in ``api/``
because it depends on the app factory; it introspects routes only and touches
no database.

The schema is written to an explicit path rather than stdout on purpose:
importing :mod:`traccio.api.main` runs ``app = create_app()`` at module load,
which emits an ``app.startup`` log line to stdout. Sharing stdout between that
log and the JSON would corrupt the file, so the two never meet.
"""

import json
import sys
from pathlib import Path
from typing import Any

from traccio.api.main import create_app


def generate_openapi() -> dict[str, Any]:
    """Build the app and return its OpenAPI schema.

    Returns
    -------
    dict[str, Any]
        The FastAPI-generated OpenAPI document.
    """
    return create_app().openapi()


def render() -> str:
    """Render the schema as deterministic, newline-terminated JSON text.

    Returns
    -------
    str
        The schema serialised with sorted keys, so the committed file diffs
        cleanly between runs.
    """
    return json.dumps(generate_openapi(), indent=2, sort_keys=True) + "\n"


def main(argv: list[str] | None = None) -> None:
    """Write the OpenAPI schema as JSON to the given output path.

    Parameters
    ----------
    argv : list[str] | None, optional
        Command-line arguments; defaults to ``sys.argv[1:]``. Exactly one
        argument is expected: the output file path.

    Returns
    -------
    None
    """
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        raise SystemExit("usage: python -m traccio.api.export_openapi <output-path>")
    Path(args[0]).write_text(render(), encoding="utf-8")


if __name__ == "__main__":
    main()
