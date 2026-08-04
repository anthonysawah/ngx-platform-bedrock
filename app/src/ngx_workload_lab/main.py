"""API Lambda — everything that needs the public AWS APIs.

Runs *outside* the VPC. Handles HTTP, calls Bedrock (both intent parsing and
run summarization), reads/writes DynamoDB, and pulls the Aurora ACU series
from CloudWatch. It never touches Postgres directly.

The executor Lambda (executor.py) is the mirror image: inside the VPC, no
internet, talks only to Aurora and DynamoDB. Splitting along that line is
what let us delete the NAT gateway — 58% of the monthly bill (ADR-013).

Run lifecycle across the two functions:

    POST /workloads   (here)      parse intent via Bedrock, persist spec,
                                  async-invoke the executor, return 202
    executor.handler  (in VPC)    run the workload, stream per-second metrics,
                                  set status = "summarizing"
    GET  /workloads/{id} (here)   overlay the ACU series; if status is
                                  "summarizing", call Bedrock, write the
                                  summary, set status = "complete"

That last step is why the UI's "Summarizing" phase is real work rather than
a cosmetic delay.
"""

from __future__ import annotations

import json
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

from ngx_workload_lab import __version__, acu, bedrock, storage
from ngx_workload_lab.config import Settings
from ngx_workload_lab.logging_setup import get_logger
from ngx_workload_lab.models import RunRecord, RunStatus, WorkloadCreated, WorkloadRequest

# configure_logging() runs at package import (see __init__.py) so it lands
# before any submodule's module-level get_logger().
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
def _cloudwatch_client() -> Any:
    return boto3.client("cloudwatch", region_name=get_settings().aws_region)


@lru_cache(maxsize=1)
def _lambda_client() -> Any:
    return boto3.client("lambda", region_name=get_settings().aws_region)


@lru_cache(maxsize=1)
def _runs_table() -> Any:
    s = get_settings()
    return boto3.resource("dynamodb", region_name=s.aws_region).Table(s.dynamodb_table_name)


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
    logger.info("request_completed", latency_ms=latency_ms, status=response.status_code)
    clear_contextvars()
    return response


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "version": __version__}


# API Gateway HTTP API only auto-answers OPTIONS when no route catches it.
# Our $default route catches everything, so preflight reaches Lambda and
# FastAPI would 405 — which browsers reject. 204 lets API GW's CORS headers
# through cleanly.
@app.options("/{full_path:path}")
async def cors_preflight(full_path: str) -> Response:
    return Response(status_code=204)


@app.post("/workloads", status_code=202)
async def create_workload(req: WorkloadRequest) -> dict[str, Any]:
    """Parse intent synchronously, then hand the workload to the executor."""
    settings = get_settings()
    table = _runs_table()
    run_id = str(uuid.uuid4())
    now = datetime.now(UTC)

    storage.put_run_header(
        table, RunRecord(run_id=run_id, status="pending", created_at=now, updated_at=now)
    )

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

    # Stash the user's verbatim text before persisting (ADR-011). Bedrock may
    # have set clamp_notes; never overwrite that here.
    spec = spec.model_copy(update={"original_prompt": req.prompt})

    if spec.clamp_notes:
        logger.info("workload_clamped", run_id=run_id, clamp_notes=spec.clamp_notes)

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

    _lambda_client().invoke(
        FunctionName=settings.executor_function_name,
        InvocationType="Event",
        Payload=json.dumps({"run_id": run_id, "spec": spec.model_dump()}).encode(),
    )

    return WorkloadCreated(run_id=run_id, status="running", spec=spec).model_dump(mode="json")


@app.get("/workloads/{run_id}")
async def get_workload(run_id: str) -> dict[str, Any]:
    """Return the run, ACU overlaid, finalizing the summary if it's pending."""
    table = _runs_table()
    record = storage.get_run(table, run_id)
    if record is None:
        raise HTTPException(status_code=404, detail={"run_id": run_id, "error": "not found"})

    metrics = storage.get_run_metrics(table, run_id)
    series = _acu_series_for(record)
    metrics = acu.overlay_acu(metrics, series)

    if record.status == "summarizing":
        record = _finalize_run(table, record, metrics, series)

    payload = record.model_dump(mode="json")
    payload["metrics"] = [m.model_dump(mode="json") for m in metrics]
    return payload


@app.get("/workloads")
async def list_workloads() -> dict[str, list[dict[str, Any]]]:
    """Up to the 20 most recent complete runs."""
    records = storage.list_recent_runs_by_status(_runs_table(), status="complete", limit=20)
    return {"runs": [r.model_dump(mode="json") for r in records]}


# ---------- ACU overlay + summarization ----------


def _acu_series_for(record: RunRecord) -> list[tuple[datetime, float]]:
    """Pull the ACU series covering a run's window. Never fatal."""
    start = record.started_at or record.created_at
    end = record.completed_at or datetime.now(UTC)
    try:
        return acu.fetch_acu_series(
            _cloudwatch_client(), get_settings().aurora_cluster_identifier, start, end
        )
    except Exception as e:
        logger.warning("acu_series_fetch_failed", run_id=record.run_id, error=str(e))
        return []


def _finalize_run(
    table: Any,
    record: RunRecord,
    metrics: list[Any],
    series: list[tuple[datetime, float]],
) -> RunRecord:
    """Write the Bedrock summary and flip the run to complete.

    The executor cannot do this — Bedrock needs internet and the executor has
    none. Runs sit in `summarizing` until the first poll lands here.
    """
    starting_acu, peak_acu = acu.summarize_series(series)
    settings = get_settings()

    try:
        summary, usage = bedrock.summarize_run(
            _bedrock_client(),
            settings.bedrock_model_id,
            record.spec,
            metrics,
            starting_acu,
            peak_acu,
        )
    except Exception as e:
        logger.exception("summary_failed", run_id=record.run_id)
        storage.update_run_header(
            table, record.run_id, status="bedrock_error", updates={"error": str(e)[:512]}
        )
        return record.model_copy(update={"status": "bedrock_error", "error": str(e)[:512]})

    final_status: RunStatus = "complete"
    updates = {
        "starting_acu": starting_acu,
        "peak_acu": peak_acu,
        "summary": summary,
        "bedrock_input_tokens": (record.bedrock_input_tokens or 0) + usage.input_tokens,
        "bedrock_output_tokens": (record.bedrock_output_tokens or 0) + usage.output_tokens,
    }
    storage.update_run_header(table, record.run_id, status=final_status, updates=updates)
    logger.info(
        "run_finalized",
        run_id=record.run_id,
        starting_acu=starting_acu,
        peak_acu=peak_acu,
        acu_datapoints=len(series),
    )
    return record.model_copy(update={"status": final_status, **updates})


handler = Mangum(app, lifespan="off")
