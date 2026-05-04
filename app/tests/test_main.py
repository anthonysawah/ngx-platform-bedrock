from __future__ import annotations

from fastapi.testclient import TestClient

from ngx_workload_lab import __version__
from ngx_workload_lab.main import app


def test_health_returns_ok() -> None:
    client = TestClient(app)
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": __version__}
    assert response.headers["x-request-id"]


def test_health_propagates_request_id() -> None:
    client = TestClient(app)
    response = client.get("/health", headers={"x-request-id": "test-req-1"})
    assert response.status_code == 200
    assert response.headers["x-request-id"] == "test-req-1"
