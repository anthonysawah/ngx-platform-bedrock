"""DynamoDB persistence helpers for run records and per-second metrics.

Item layout:
  Header row:    PK=run_id, SK="run", attributes from RunRecord, plus
                 status + created_at (the GSI keys).
  Per-second:    PK=run_id, SK=ISO8601 timestamp, attributes from MetricSample.

The GSI `status-created_at` is sparse — only header rows have both keys,
so it indexes only headers. Used by list_recent_runs.

Float → Decimal conversion goes through json.dumps + parse_float=Decimal,
which is the canonical pattern for Pydantic models that want to land in
DynamoDB without losing numeric precision.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from boto3.dynamodb.conditions import Key

from ngx_workload_lab.logging_setup import get_logger
from ngx_workload_lab.models import MetricSample, RunRecord

logger = get_logger("ngx_workload_lab.storage")

HEADER_SK = "run"
GSI_NAME = "status-created_at"


def put_run_header(table: Any, record: RunRecord) -> None:
    item = _to_ddb_item(record.model_dump_json())
    item["metric_ts"] = HEADER_SK
    table.put_item(Item=item)


def update_run_header(
    table: Any,
    run_id: str,
    *,
    status: str,
    updates: dict[str, Any],
) -> None:
    """Update the header row in-place. `updates` is a dict of attribute → value."""
    expression_names: dict[str, str] = {"#status": "status", "#updated_at": "updated_at"}
    expression_values: dict[str, Any] = {
        ":status": status,
        ":updated_at": datetime.now(tz=UTC).isoformat(),
    }
    set_clauses = ["#status = :status", "#updated_at = :updated_at"]

    for i, (key, value) in enumerate(updates.items()):
        name_placeholder = f"#u{i}"
        value_placeholder = f":u{i}"
        expression_names[name_placeholder] = key
        expression_values[value_placeholder] = _normalize_for_ddb(value)
        set_clauses.append(f"{name_placeholder} = {value_placeholder}")

    table.update_item(
        Key={"run_id": run_id, "metric_ts": HEADER_SK},
        UpdateExpression="SET " + ", ".join(set_clauses),
        ExpressionAttributeNames=expression_names,
        ExpressionAttributeValues=expression_values,
    )


def put_metric_samples(table: Any, samples: list[MetricSample]) -> None:
    if not samples:
        return
    with table.batch_writer() as batch:
        for s in samples:
            item = _to_ddb_item(s.model_dump_json())
            batch.put_item(Item=item)


def get_run(table: Any, run_id: str) -> RunRecord | None:
    response = table.get_item(Key={"run_id": run_id, "metric_ts": HEADER_SK})
    item = response.get("Item")
    if not item:
        return None
    return RunRecord.model_validate(_from_ddb_item(item))


def list_recent_runs_by_status(table: Any, status: str, limit: int = 20) -> list[RunRecord]:
    """Query the GSI for the most recent N runs of a given status.

    Most recent first (descending on the SK created_at).
    """
    response = table.query(
        IndexName=GSI_NAME,
        KeyConditionExpression=Key("status").eq(status),
        ScanIndexForward=False,
        Limit=limit,
    )
    return [RunRecord.model_validate(_from_ddb_item(i)) for i in response.get("Items", [])]


# ---------- internals ----------


def _to_ddb_item(json_str: str) -> dict[str, Any]:
    """Pydantic model_dump_json → dict suitable for DynamoDB high-level API.

    parse_float=Decimal lands every numeric scalar as Decimal, which is what
    the boto3 DynamoDB resource expects.
    """
    return json.loads(json_str, parse_float=Decimal)


def _normalize_for_ddb(value: Any) -> Any:
    """Recursive coercion for UpdateItem expression values.

    DynamoDB rejects Python floats — they must be Decimal. Datetimes go
    to ISO 8601 strings. Walks nested dicts and lists so a serialized
    Pydantic model passed to `updates` is fully Decimal-clean.
    """
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {k: _normalize_for_ddb(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_normalize_for_ddb(v) for v in value]
    return value


def _from_ddb_item(item: dict[str, Any]) -> dict[str, Any]:
    """Pre-validation cleanup: drop the SK sentinel; let Pydantic ignore extras."""
    cleaned = {k: _from_ddb_value(v) for k, v in item.items() if k != "metric_ts"}
    return cleaned


def _from_ddb_value(value: Any) -> Any:
    if isinstance(value, Decimal):
        # Pydantic v2 will coerce these correctly, but float is friendlier
        # for downstream JSON serialization.
        return float(value)
    return value
