"""Tests for the health endpoint."""

from importlib.metadata import version

from fastapi.testclient import TestClient

from traccio.api.main import create_app


def test_health_returns_ok_and_version() -> None:
    client = TestClient(create_app())

    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"] == version("traccio")
