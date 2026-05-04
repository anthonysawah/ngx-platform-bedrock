from __future__ import annotations

import json
from datetime import UTC, datetime
from unittest.mock import Mock

import pytest

from ngx_workload_lab.bedrock import (
    BedrockValidationError,
    parse_intent,
    summarize_run,
)
from ngx_workload_lab.models import MetricSample, WorkloadSpec


def _converse_response(text: str, *, in_tokens: int = 100, out_tokens: int = 50) -> dict:
    return {
        "output": {"message": {"content": [{"text": text}]}},
        "usage": {"inputTokens": in_tokens, "outputTokens": out_tokens},
    }


# ---------- parse_intent ----------


def test_parse_intent_returns_validated_spec_and_usage() -> None:
    payload = {
        "workload_type": "mixed",
        "row_count": 50_000,
        "mix_ratio": 0.3,
        "duration_seconds": 120,
        "table_name": "workload_orders",
    }
    client = Mock()
    client.converse.return_value = _converse_response(json.dumps(payload))

    spec, usage = parse_intent(client, "model-id", "insert 50k orders mixed reads")

    assert isinstance(spec, WorkloadSpec)
    assert spec.workload_type == "mixed"
    assert spec.row_count == 50_000
    assert usage.input_tokens == 100
    assert usage.output_tokens == 50

    args = client.converse.call_args.kwargs
    assert args["modelId"] == "model-id"
    assert args["inferenceConfig"]["maxTokens"] == 1024
    assert args["inferenceConfig"]["temperature"] == 0.0
    assert args["messages"][0]["role"] == "user"


def test_parse_intent_strips_markdown_code_fence() -> None:
    payload = {
        "workload_type": "insert",
        "row_count": 100,
        "mix_ratio": 0.0,
        "duration_seconds": 5,
        "table_name": "workload_orders",
    }
    fenced = "```json\n" + json.dumps(payload) + "\n```"
    client = Mock()
    client.converse.return_value = _converse_response(fenced)

    spec, _ = parse_intent(client, "model-id", "insert 100 rows")

    assert spec.row_count == 100


def test_parse_intent_raises_on_non_json() -> None:
    client = Mock()
    client.converse.return_value = _converse_response("not even close to json")

    with pytest.raises(BedrockValidationError) as exc:
        parse_intent(client, "model-id", "go")

    assert exc.value.raw_text == "not even close to json"
    assert exc.value.errors[0]["type"] == "json_decode"


def test_parse_intent_raises_on_schema_violation_with_raw_text() -> None:
    bad_payload = {
        "workload_type": "delete",  # not in the Literal
        "row_count": 100,
        "mix_ratio": 0.0,
        "duration_seconds": 5,
        "table_name": "workload_orders",
    }
    client = Mock()
    client.converse.return_value = _converse_response(json.dumps(bad_payload))

    with pytest.raises(BedrockValidationError) as exc:
        parse_intent(client, "model-id", "delete everything")

    assert "delete" in exc.value.raw_text
    assert exc.value.errors  # non-empty Pydantic errors


def test_parse_intent_rejects_disallowed_table_name() -> None:
    bad_payload = {
        "workload_type": "insert",
        "row_count": 100,
        "mix_ratio": 0.0,
        "duration_seconds": 5,
        "table_name": "users",  # not in ALLOWED_TABLE_NAMES
    }
    client = Mock()
    client.converse.return_value = _converse_response(json.dumps(bad_payload))

    with pytest.raises(BedrockValidationError) as exc:
        parse_intent(client, "model-id", "anything")

    assert any("table_name" in str(e) for e in exc.value.errors)


# ---------- summarize_run ----------


def _metrics(n: int, *, base_p50: float = 3.0, base_p95: float = 8.0) -> list[MetricSample]:
    return [
        MetricSample(
            run_id="r-1",
            metric_ts=datetime(2026, 5, 4, 14, 0, i, tzinfo=UTC),
            second_offset=i,
            rows_inserted=100,
            selects_done=30,
            p50_latency_ms=base_p50,
            p95_latency_ms=base_p95,
            current_acu=0.5,
        )
        for i in range(n)
    ]


def test_summarize_run_passes_acu_and_aggregates_to_bedrock() -> None:
    spec = WorkloadSpec(
        workload_type="mixed",
        row_count=10_000,
        mix_ratio=0.3,
        duration_seconds=10,
        table_name="workload_orders",
    )
    metrics = _metrics(10)

    captured: dict = {}

    def fake_converse(**kwargs):
        captured.update(kwargs)
        return _converse_response("Mixed workload completed in 10 seconds.")

    client = Mock()
    client.converse.side_effect = fake_converse

    text, usage = summarize_run(client, "model-id", spec, metrics, starting_acu=0.5, peak_acu=2.0)

    assert text == "Mixed workload completed in 10 seconds."
    assert usage.input_tokens == 100

    user_payload = json.loads(captured["messages"][0]["content"][0]["text"])
    assert user_payload["results"]["starting_acu"] == 0.5
    assert user_payload["results"]["peak_acu"] == 2.0
    assert user_payload["results"]["cluster_scaled"] is True
    assert user_payload["results"]["rows_inserted"] == 1000
    assert user_payload["results"]["selects_completed"] == 300
    assert user_payload["spec"]["row_count_target"] == 10_000


def test_summarize_run_marks_no_scaling_when_acu_unchanged() -> None:
    spec = WorkloadSpec(
        workload_type="insert",
        row_count=500,
        mix_ratio=0.0,
        duration_seconds=5,
        table_name="workload_orders",
    )
    metrics = _metrics(5)

    captured: dict = {}

    def fake_converse(**kwargs):
        captured.update(kwargs)
        return _converse_response("Cluster did not scale.")

    client = Mock()
    client.converse.side_effect = fake_converse

    summarize_run(client, "model-id", spec, metrics, starting_acu=0.5, peak_acu=0.5)

    user_payload = json.loads(captured["messages"][0]["content"][0]["text"])
    assert user_payload["results"]["cluster_scaled"] is False
