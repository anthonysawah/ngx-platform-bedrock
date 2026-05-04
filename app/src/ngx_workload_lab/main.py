from __future__ import annotations

import json
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
from ngx_workload_lab.logging_setup import get_logger
from ngx_workload_lab.models import (
    RunRecord,
    RunStatus,
    WorkloadCreated,
    WorkloadRequest,
    WorkloadSpec,
)

# Sentinel field on async self-invocation events. The Lambda handler routes
# to the worker path when this key is present, otherwise it forwards the
# event to Mangum (HTTP API path). See ADR-012.
ASYNC_EVENT_KEY = "_ngx_async_workload"

# configure_logging() runs at package import (ngx_workload_lab/__init__.py)
# so it lands BEFORE any submodule's module-level get_logger() — see the
# comment in __init__.py for the cache_logger_on_first_use rationale.
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
def _lambda_client() -> Any:
    return boto3.client("lambda", region_name=get_settings().aws_region)


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


# CORS preflight: API Gateway HTTP API CORS only auto-intercepts OPTIONS when
# no route catches it. Our $default route catches everything (including
# OPTIONS), so the preflight reaches Lambda — FastAPI 405s by default and the
# browser rejects the preflight. Returning 204 here lets API GW's response
# headers (allow-origin, allow-methods, allow-headers) pass through cleanly.
@app.options("/{full_path:path}")
async def cors_preflight(full_path: str) -> Response:
    return Response(status_code=204)


@app.post("/workloads", status_code=202)
async def create_workload(req: WorkloadRequest) -> dict[str, Any]:
    """Async kick-off. Parses intent synchronously (so a bad prompt still
    returns 400 right away), persists a `running` RunRecord with the spec,
    self-invokes the Lambda with InvocationType=Event to run the workload
    out-of-band, and returns 202 + run_id immediately. UI polls
    GET /workloads/{run_id} for status. See ADR-012.
    """
    settings = get_settings()
    table = _runs_table()
    run_id = str(uuid.uuid4())
    now = datetime.now(UTC)

    placeholder = RunRecord(
        run_id=run_id,
        status="pending",
        created_at=now,
        updated_at=now,
    )
    storage.put_run_header(table, placeholder)

    try:
        spec, parse_usage = bedrock.parse_intent(
            _bedrock_client(), settings.bedrock_model_id, req.prompt
        )
    except bedrock.BedrockValidationError as e:
        storage.update_run_header(
            table,
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

    # Stash the user's verbatim text on the spec before persisting (ADR-011).
    # Bedrock may have set `clamp_notes`; we never overwrite that here.
    spec = spec.model_copy(update={"original_prompt": req.prompt})

    storage.update_run_header(
        table,
        run_id,
        status="running",
        updates={
            "spec": spec.model_dump(),
            "bedrock_input_tokens": parse_usage.input_tokens,
            "bedrock_output_tokens": parse_usage.output_tokens,
        },
    )

    function_name = os.environ.get("AWS_LAMBDA_FUNCTION_NAME")
    if not function_name:
        # Local dev fallback: run synchronously inline. Lambda always sets this.
        logger.warning("no_lambda_function_name_falling_back_to_inline_run")
        _run_async_worker(run_id, spec, parse_usage)
    else:
        _lambda_client().invoke(
            FunctionName=function_name,
            InvocationType="Event",
            Payload=json.dumps(
                {
                    ASYNC_EVENT_KEY: True,
                    "run_id": run_id,
                    "spec": spec.model_dump(),
                    "parse_input_tokens": parse_usage.input_tokens,
                    "parse_output_tokens": parse_usage.output_tokens,
                }
            ).encode(),
        )

    return WorkloadCreated(run_id=run_id, status="running", spec=spec).model_dump(mode="json")


@app.get("/workloads/{run_id}")
async def get_workload(run_id: str) -> dict[str, Any]:
    record = storage.get_run(_runs_table(), run_id)
    if record is None:
        raise HTTPException(status_code=404, detail={"run_id": run_id, "error": "not found"})

    metrics = storage.get_run_metrics(_runs_table(), run_id)
    payload = record.model_dump(mode="json")
    payload["metrics"] = [m.model_dump(mode="json") for m in metrics]
    return payload


@app.get("/workloads")
async def list_workloads() -> dict[str, list[dict[str, Any]]]:
    """Return up to the 20 most recent COMPLETE runs.

    v1 keeps this simple — non-complete runs are still discoverable via
    GET /workloads/{run_id}. v1.5 may surface in-progress and errored
    runs via additional GSI queries.
    """
    records = storage.list_recent_runs_by_status(_runs_table(), status="complete", limit=20)
    return {"runs": [r.model_dump(mode="json") for r in records]}


# ---------- async worker path ----------


def _run_async_worker(run_id: str, spec: WorkloadSpec, parse_usage: bedrock.BedrockUsage) -> None:
    """Invoked via Lambda async self-invocation (or inline in local dev).

    Runs the executor, persists per-second metrics, calls Bedrock for the
    summary, and writes the final RunRecord. Errors land as a workload_error
    RunRecord so the UI can show them.
    """
    settings = get_settings()
    table = _runs_table()
    started = datetime.now(UTC)

    storage.update_run_header(
        table, run_id, status="running", updates={"started_at": started.isoformat()}
    )

    try:
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
        logger.info(
            "workload_async_complete",
            run_id=run_id,
            rows=rows_completed,
            selects=selects_completed,
            starting_acu=starting_acu,
            peak_acu=peak_acu,
        )
    except Exception as e:
        logger.exception("workload_async_failure", run_id=run_id)
        storage.update_run_header(
            table,
            run_id,
            status="workload_error",
            updates={"error": str(e)[:512]},
        )


def _run_executor(
    spec: WorkloadSpec, run_id: str, settings: Settings
) -> tuple[list, float, float, int, int]:
    dsn = _build_dsn()
    with workload.WorkloadExecutor(
        spec=spec,
        run_id=run_id,
        dsn=dsn,
        cloudwatch_client=_cloudwatch_client(),
        cluster_identifier=settings.aurora_cluster_identifier,
    ) as executor:
        return executor.run()


# ---------- Lambda handler dispatch ----------

_mangum_handler = Mangum(app, lifespan="off")


def handler(event: Any, context: Any) -> Any:
    """Top-level Lambda entry point.

    Dispatches between two event shapes:
      - HTTP API events from API Gateway (handled by Mangum → FastAPI).
      - Self-invoked async events with ASYNC_EVENT_KEY (run the worker).
    """
    if isinstance(event, dict) and event.get(ASYNC_EVENT_KEY):
        run_id = event["run_id"]
        spec = WorkloadSpec.model_validate(event["spec"])
        usage = bedrock.BedrockUsage(
            input_tokens=int(event.get("parse_input_tokens", 0)),
            output_tokens=int(event.get("parse_output_tokens", 0)),
        )
        _run_async_worker(run_id, spec, usage)
        return {"ok": True}

    return _mangum_handler(event, context)
