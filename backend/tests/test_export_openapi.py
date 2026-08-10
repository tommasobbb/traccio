"""Tests for the OpenAPI export script."""

import json
from pathlib import Path

from traccio.api.export_openapi import generate_openapi, main


def test_generate_openapi_exposes_versioned_paths() -> None:
    """The schema carries an OpenAPI version and both public paths.

    Guards that the export reflects the real app wiring: the ``openapi``
    version marker is present and the routes the client depends on
    (``/health``, ``/accounts``) are exposed.
    """
    # Act: build the schema straight from the app factory.
    schema = generate_openapi()

    # Assert: it is a versioned OpenAPI document exposing both paths.
    assert schema["openapi"]  # non-empty version string
    assert "/health" in schema["paths"]
    assert "/accounts" in schema["paths"]


def test_main_writes_valid_json_file(tmp_path: Path) -> None:
    """``main`` writes a file that is pure JSON, not corrupted by log output.

    This is the regression guard: importing the app factory emits an
    ``app.startup`` line to stdout, so the script writes the schema to an
    explicit path instead. The written file must parse as JSON and carry the
    routes the client consumes.
    """
    # Arrange: an output path inside the test's temp dir.
    out = tmp_path / "openapi.json"

    # Act: run the entry point against that path.
    main([str(out)])

    # Assert: the file round-trips as the OpenAPI document.
    parsed = json.loads(out.read_text(encoding="utf-8"))
    assert parsed["openapi"]
    assert "/accounts" in parsed["paths"]


def test_schema_never_leaks_token_fields() -> None:
    """No token-like field name reaches the schema (data-safety rule).

    Tokens must never appear in the OpenAPI schema — see
    ``.claude/rules/data-safety.md``. Serialising the whole document and
    checking for the substring is a cheap, future-proof guard against a new
    schema accidentally exposing one.
    """
    # Act: serialise the full schema to text.
    serialised = json.dumps(generate_openapi()).lower()

    # Assert: no token field slipped into any component or route.
    assert "token" not in serialised
