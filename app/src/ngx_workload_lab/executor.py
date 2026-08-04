"""Executor Lambda entry point — the only code that touches Aurora.

Runs in private subnets with **no internet path**: no NAT gateway, no VPC
interface endpoints, no public IP. Its entire dependency surface is:

  * Aurora  — private IP inside the VPC, authenticated with a locally-signed
              IAM token (no Secrets Manager call, see workload.build_iam_auth_dsn)
  * DynamoDB — free S3/DynamoDB *gateway* endpoint, which is route-table
              based and needs no internet either

Everything that requires the public AWS APIs — Bedrock summarization and
CloudWatch ACU sampling — lives in the API Lambda instead. That split is
what let us delete the NAT gateway, which was 58% of the monthly bill
(ADR-013).

Invoked asynchronously (InvocationType="Event") by the API Lambda.
"""

from __future__ import annotations

from datetime import UTC, datetime
from functools import lru_cache
from typing import Any

import boto3

from ngx_workload_lab import storage, workload
from ngx_workload_lab.config import Settings
from ngx_workload_lab.logging_setup import get_logger
from ngx_workload_lab.models import WorkloadSpec

logger = get_logger("ngx_workload_lab.executor")


@lru_cache(maxsize=1)
def _settings() -> Settings:
    return Settings.from_env()


@lru_cache(maxsize=1)
def _runs_table() -> Any:
    s = _settings()
    return boto3.resource("dynamodb", region_name=s.aws_region).Table(s.dynamodb_table_name)


def handler(event: Any, context: Any) -> dict[str, Any]:
    """Run one workload to completion, then hand off for summarization.

    Terminal state here is `summarizing`, not `complete`: writing the
    Bedrock summary needs internet, so the API Lambda finalizes the run on
    the next poll. That also makes the UI's "Summarizing" step reflect real
    work instead of a cosmetic delay.
    """
    # Break-glass: re-run the rds_iam grant. Needs Secrets Manager, which this
    # Lambda cannot reach post-refactor -- see the recovery procedure in
    # DECISIONS ADR-013. Left wired so the path is discoverable, not hidden.
    if event.get("_ngx_bootstrap"):
        from ngx_workload_lab import bootstrap

        s = _settings()
        creds = workload.fetch_db_credentials(
            boto3.client("secretsmanager", region_name=s.aws_region), s.aurora_secret_arn
        )
        return bootstrap.run_bootstrap(
            host=s.aurora_cluster_endpoint,
            port=s.aurora_port,
            dbname=s.aurora_database_name,
            master_user=creds["username"],
            master_password=creds["password"],
            region=s.aws_region,
        )

    run_id = event["run_id"]
    spec = WorkloadSpec.model_validate(event["spec"])
    s = _settings()
    table = _runs_table()

    storage.update_run_header(
        table,
        run_id,
        status="running",
        updates={"started_at": datetime.now(UTC).isoformat()},
    )

    try:
        dsn = workload.build_iam_auth_dsn(
            host=s.aurora_cluster_endpoint,
            port=s.aurora_port,
            dbname=s.aurora_database_name,
            username=s.aurora_iam_db_user,
            region=s.aws_region,
        )

        def metric_sink(sample: Any) -> None:
            # Best-effort live streaming; the final write below is the
            # authoritative one, so a dropped flush self-heals.
            try:
                storage.put_metric_samples(table, [sample])
            except Exception as e:
                logger.warning("metric_sink_failed", run_id=run_id, error=str(e))

        with workload.WorkloadExecutor(
            spec=spec, run_id=run_id, dsn=dsn, metric_sink=metric_sink
        ) as ex:
            metrics, rows_completed, selects_completed = ex.run()

        storage.put_metric_samples(table, metrics)
        storage.update_run_header(
            table,
            run_id,
            status="summarizing",
            updates={
                "rows_completed": rows_completed,
                "selects_completed": selects_completed,
                "completed_at": datetime.now(UTC).isoformat(),
            },
        )
        logger.info(
            "executor_finished",
            run_id=run_id,
            rows=rows_completed,
            selects=selects_completed,
            samples=len(metrics),
        )
        return {"ok": True, "run_id": run_id, "rows": rows_completed}

    except Exception as e:
        logger.exception("executor_failed", run_id=run_id)
        storage.update_run_header(
            table, run_id, status="workload_error", updates={"error": str(e)[:512]}
        )
        return {"ok": False, "run_id": run_id, "error": str(e)[:512]}
