"""Tests for the health endpoint."""

from importlib.metadata import version

from fastapi.testclient import TestClient

from traccio.api.main import create_app


def test_health_returns_ok_and_version() -> None:
    """GET /health returns 200 with status ``ok`` and the package version.

    Builds a fresh app via the factory so the test exercises the same wiring
    (config, logging, routes) that production uses.
    """
    # Arrange: a client over a freshly built app.
    client = TestClient(create_app())

    # Act: hit the health endpoint.
    response = client.get("/health")

    # Assert: success, liveness marker, and the version read from metadata.
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"] == version("traccio")
