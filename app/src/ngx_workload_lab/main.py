from __future__ import annotations

import asyncio
import os
import time
import uuid
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from functools import lru_cache
from typing import Any

import boto3
from fastapi import FastAPI, HTTPException, Request, Response
from mangum import Mangum
from structlog.contextvars import bind_contextvars, clear_contextvars

from ngx_workload_lab import __version__, bedrock, storage, workload
from ngx_workload_lab.config import Settings
from ngx_workload_lab.logging_setup import configure_logging, get_logger
from ngx_workload_lab.models import (
    MetricSample,
    RunRecord,
    RunStatus,
    WorkloadCreated,
    WorkloadRequest,
    WorkloadSpec,
)

# Total budget for the synchronous request path. API Gateway HTTP API
# integration timeout caps at 30s; we leave 2s buffer for response
# serialization. ADR-009 has the rationale.
REQUEST_DEADLINE_SECONDS = 28.0

configure_logging(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = get_logger("ngx_workload_lab")

app = FastAPI(
    title="ai-workload-lab",
    version=__version__,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings.from_env()


@lru_cache(maxsize=1)
def _bedrock_client() -> Any:
    return boto3.client("bedrock-runtime", region_name=get_settings().aws_region)


@lru_cache(maxsize=1)
def _secrets_client() -> Any:
    return boto3.client("secretsmanager", region_name=get_settings().aws_region)


@lru_cache(maxsize=1)
def _cloudwatch_client() -> Any:
    return boto3.client("cloudwatch", region_name=get_settings().aws_region)


@lru_cache(maxsize=1)
def _runs_table() -> Any:
    return boto3.resource("dynamodb", region_name=get_settings().aws_region).Table(
        get_settings().dynamodb_table_name
    )


@lru_cache(maxsize=1)
def _db_credentials() -> dict[str, str]:
    return workload.fetch_db_credentials(_secrets_client(), get_settings().aurora_secret_arn)


def _build_dsn() -> str:
    s = get_settings()
    creds = _db_credentials()
    return workload.build_dsn(
        host=s.aurora_cluster_endpoint,
        port=s.aurora_port,
        dbname=s.aurora_database_name,
        username=creds["username"],
        password=creds["password"],
    )


@app.middleware("http")
async def request_logging(
    request: Request, call_next: Callable[[Request], Awaitable[Response]]
) -> Response:
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    bind_contextvars(request_id=request_id, route=request.url.path, method=request.method)

    started = time.perf_counter()
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


@app.post("/workloads", status_code=201)
async def create_workload(req: WorkloadRequest) -> dict[str, Any]:
    run_id = str(uuid.uuid4())
    now = datetime.now(UTC)

    # Persist a placeholder so even a Bedrock failure leaves an auditable row.
    placeholder = RunRecord(
        run_id=run_id,
        status="pending",
        created_at=now,
        updated_at=now,
    )
    storage.put_run_header(_runs_table(), placeholder)

    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(_run_workload_sync, run_id, req.prompt),
            timeout=REQUEST_DEADLINE_SECONDS,
        )
    except TimeoutError:
        storage.update_run_header(
            _runs_table(),
            run_id,
            status="timeout",
            updates={"error": "Request exceeded synchronous deadline."},
        )
        raise HTTPException(
            status_code=504,
            detail={"run_id": run_id, "error": "Workload exceeded the synchronous request budget."},
        ) from None
    except bedrock.BedrockValidationError as e:
        storage.update_run_header(
            _runs_table(),
            run_id,
            status="bedrock_error",
            updates={"error": "intent_parser produced invalid WorkloadSpec"},
        )
        raise HTTPException(
            status_code=400,
            detail={
                "run_id": run_id,
                "error": "Bedrock returned an invalid WorkloadSpec.",
                "raw_model_output": e.raw_text,
                "validation_errors": e.errors,
            },
        ) from e
    except Exception as e:
        logger.exception("workload_unexpected_failure", run_id=run_id)
        storage.update_run_header(
            _runs_table(),
            run_id,
            status="workload_error",
            updates={"error": str(e)[:512]},
        )
        raise HTTPException(
            status_code=500,
            detail={"run_id": run_id, "error": "Workload execution failed."},
        ) from e

    return WorkloadCreated(run_id=run_id, status=result.status, spec=result.spec).model_dump(
        mode="json"
    )


@app.get("/workloads/{run_id}")
async def get_workload(run_id: str) -> dict[str, Any]:
    record = storage.get_run(_runs_table(), run_id)
    if record is None:
        raise HTTPException(status_code=404, detail={"run_id": run_id, "error": "not found"})
    return record.model_dump(mode="json")


@app.get("/workloads")
async def list_workloads() -> dict[str, list[dict[str, Any]]]:
    """Return up to the 20 most recent COMPLETE runs.

    v1 keeps this simple — non-complete runs are still discoverable via
    GET /workloads/{run_id}. v1.5 may surface in-progress and errored
    runs via additional GSI queries.
    """
    records = storage.list_recent_runs_by_status(_runs_table(), status="complete", limit=20)
    return {"runs": [r.model_dump(mode="json") for r in records]}


# ---------- workload orchestration ----------


def _run_workload_sync(run_id: str, prompt: str) -> RunRecord:
    """Bedrock parse → workload run → metric persistence → Bedrock summary.

    Runs in a worker thread (asyncio.to_thread) so blocking psycopg + boto3
    calls don't block the FastAPI event loop. The wrapping
    asyncio.wait_for enforces the request deadline.
    """
    settings = get_settings()
    table = _runs_table()
    started = datetime.now(UTC)

    storage.update_run_header(
        table, run_id, status="running", updates={"started_at": started.isoformat()}
    )

    spec, parse_usage = bedrock.parse_intent(_bedrock_client(), settings.bedrock_model_id, prompt)
    logger.info("intent_parsed", run_id=run_id, spec=spec.model_dump())

    storage.update_run_header(
        table,
        run_id,
        status="running",
        updates={"spec": spec.model_dump()},
    )

    metrics, starting_acu, peak_acu, rows_completed, selects_completed = _run_executor(
        spec, run_id, settings
    )

    storage.put_metric_samples(table, metrics)

    summary, summary_usage = bedrock.summarize_run(
        _bedrock_client(),
        settings.bedrock_model_id,
        spec,
        metrics,
        starting_acu,
        peak_acu,
    )
    completed = datetime.now(UTC)

    final_status: RunStatus = "complete"
    storage.update_run_header(
        table,
        run_id,
        status=final_status,
        updates={
            "completed_at": completed.isoformat(),
            "rows_completed": rows_completed,
            "selects_completed": selects_completed,
            "starting_acu": starting_acu,
            "peak_acu": peak_acu,
            "summary": summary,
            "bedrock_input_tokens": parse_usage.input_tokens + summary_usage.input_tokens,
            "bedrock_output_tokens": parse_usage.output_tokens + summary_usage.output_tokens,
        },
    )

    return RunRecord(
        run_id=run_id,
        status=final_status,
        spec=spec,
        created_at=started,
        updated_at=completed,
        started_at=started,
        completed_at=completed,
        rows_completed=rows_completed,
        selects_completed=selects_completed,
        starting_acu=starting_acu,
        peak_acu=peak_acu,
        summary=summary,
        bedrock_input_tokens=parse_usage.input_tokens + summary_usage.input_tokens,
        bedrock_output_tokens=parse_usage.output_tokens + summary_usage.output_tokens,
    )


def _run_executor(
    spec: WorkloadSpec, run_id: str, settings: Settings
) -> tuple[list[MetricSample], float, float, int, int]:
    dsn = _build_dsn()
    with workload.WorkloadExecutor(
        spec=spec,
        run_id=run_id,
        dsn=dsn,
        cloudwatch_client=_cloudwatch_client(),
        cluster_identifier=settings.aurora_cluster_identifier,
    ) as executor:
        return executor.run()


handler = Mangum(app, lifespan="off")
