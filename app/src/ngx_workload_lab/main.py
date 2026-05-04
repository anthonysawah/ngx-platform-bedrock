from __future__ import annotations

import os
import time
import uuid
from collections.abc import Awaitable, Callable

from fastapi import FastAPI, Request, Response
from mangum import Mangum
from structlog.contextvars import bind_contextvars, clear_contextvars

from ngx_workload_lab import __version__
from ngx_workload_lab.logging_setup import configure_logging, get_logger

configure_logging(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = get_logger("ngx_workload_lab")

app = FastAPI(
    title="ai-workload-lab",
    version=__version__,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@app.middleware("http")
async def request_logging(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    bind_contextvars(request_id=request_id, route=request.url.path, method=request.method)

    started = time.perf_counter()
    response: Response
    try:
        response = await call_next(request)
    except Exception:
        latency_ms = round((time.perf_counter() - started) * 1000, 2)
        logger.exception("request_failed", latency_ms=latency_ms, status=500)
        clear_contextvars()
        raise

    latency_ms = round((time.perf_counter() - started) * 1000, 2)
    response.headers["x-request-id"] = request_id
    logger.info(
        "request_completed",
        latency_ms=latency_ms,
        status=response.status_code,
    )
    clear_contextvars()
    return response


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "version": __version__}


handler = Mangum(app, lifespan="off")
