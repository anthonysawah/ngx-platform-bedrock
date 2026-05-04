"""Bedrock Converse client wrappers — intent parser + run summary.

Both calls go through the bedrock-runtime Converse API with maxTokens=1024.
Token usage is logged on every call so a metric filter can chart cost.
The intent parser's output is validated against a Pydantic schema; on
failure the raw model text is preserved on the exception so the caller
can return a 400 with debug info.
"""

from __future__ import annotations

import json
import time
from importlib.resources import files
from typing import Any

from pydantic import BaseModel, ValidationError

from ngx_workload_lab.logging_setup import get_logger
from ngx_workload_lab.models import MetricSample, WorkloadSpec

logger = get_logger("ngx_workload_lab.bedrock")

INTENT_PARSER_SYSTEM = (
    files("ngx_workload_lab").joinpath("prompts/intent_parser.md").read_text(encoding="utf-8")
)
RUN_SUMMARY_SYSTEM = (
    files("ngx_workload_lab").joinpath("prompts/run_summary.md").read_text(encoding="utf-8")
)

MAX_TOKENS = 1024


class BedrockUsage(BaseModel):
    input_tokens: int
    output_tokens: int


class BedrockValidationError(Exception):
    """Bedrock output didn't match the WorkloadSpec schema.

    `raw_text` is whatever Bedrock returned — kept verbatim so the API
    response can include it for debugging without losing fidelity.
    """

    def __init__(self, raw_text: str, errors: list[dict[str, Any]]) -> None:
        self.raw_text = raw_text
        self.errors = errors
        super().__init__(f"Bedrock output failed schema validation: {errors}")


def parse_intent(client: Any, model_id: str, user_prompt: str) -> tuple[WorkloadSpec, BedrockUsage]:
    text, usage = _converse(
        client,
        model_id=model_id,
        system=INTENT_PARSER_SYSTEM,
        user_message=user_prompt,
        purpose="intent_parser",
    )

    cleaned = _strip_code_fence(text)

    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError as e:
        raise BedrockValidationError(
            text, [{"type": "json_decode", "msg": str(e), "pos": e.pos}]
        ) from e

    try:
        spec = WorkloadSpec.model_validate(data)
    except ValidationError as e:
        raise BedrockValidationError(text, list(e.errors())) from e

    return spec, usage


def summarize_run(
    client: Any,
    model_id: str,
    spec: WorkloadSpec,
    metrics: list[MetricSample],
    starting_acu: float,
    peak_acu: float,
) -> tuple[str, BedrockUsage]:
    user_message = _format_summary_input(spec, metrics, starting_acu, peak_acu)
    text, usage = _converse(
        client,
        model_id=model_id,
        system=RUN_SUMMARY_SYSTEM,
        user_message=user_message,
        purpose="run_summary",
    )
    return text.strip(), usage


def _converse(
    client: Any,
    *,
    model_id: str,
    system: str,
    user_message: str,
    purpose: str,
) -> tuple[str, BedrockUsage]:
    started = time.perf_counter()
    response = client.converse(
        modelId=model_id,
        system=[{"text": system}],
        messages=[{"role": "user", "content": [{"text": user_message}]}],
        inferenceConfig={"maxTokens": MAX_TOKENS, "temperature": 0.0},
    )
    latency_ms = round((time.perf_counter() - started) * 1000, 2)

    content_parts = response["output"]["message"].get("content", [])
    text = "".join(part.get("text", "") for part in content_parts)

    usage_dict = response.get("usage", {})
    usage = BedrockUsage(
        input_tokens=int(usage_dict.get("inputTokens", 0)),
        output_tokens=int(usage_dict.get("outputTokens", 0)),
    )

    logger.info(
        "bedrock_converse",
        purpose=purpose,
        model_id=model_id,
        latency_ms=latency_ms,
        input_tokens=usage.input_tokens,
        output_tokens=usage.output_tokens,
        response_chars=len(text),
    )

    return text, usage


def _strip_code_fence(text: str) -> str:
    """Strip a leading/trailing ``` code fence if present.

    Despite the prompt's instructions, Bedrock occasionally wraps the
    JSON in a fenced block. Strip it rather than fail validation on
    something cosmetic.
    """
    cleaned = text.strip()
    if not cleaned.startswith("```"):
        return cleaned

    lines = cleaned.splitlines()
    # Drop the opening fence (which may be ```json or just ```).
    lines = lines[1:]
    # Drop trailing fence if present.
    if lines and lines[-1].strip().startswith("```"):
        lines = lines[:-1]
    return "\n".join(lines).strip()


def _format_summary_input(
    spec: WorkloadSpec,
    metrics: list[MetricSample],
    starting_acu: float,
    peak_acu: float,
) -> str:
    rows_inserted = sum(m.rows_inserted for m in metrics)
    selects_done = sum(m.selects_done for m in metrics)

    p50_samples = [m.p50_latency_ms for m in metrics if m.p50_latency_ms > 0]
    p95_samples = [m.p95_latency_ms for m in metrics if m.p95_latency_ms > 0]

    overall_p50 = round(sum(p50_samples) / len(p50_samples), 2) if p50_samples else 0.0
    overall_p95 = max(p95_samples) if p95_samples else 0.0

    payload = {
        "spec": {
            "workload_type": spec.workload_type,
            "row_count_target": spec.row_count,
            "mix_ratio": spec.mix_ratio,
            "duration_seconds_target": spec.duration_seconds,
            "table_name": spec.table_name,
            "original_prompt": spec.original_prompt,
            "clamp_notes": spec.clamp_notes,
        },
        "results": {
            "actual_duration_seconds": len(metrics),
            "rows_inserted": rows_inserted,
            "selects_completed": selects_done,
            "p50_latency_ms_avg": overall_p50,
            "p95_latency_ms_max": overall_p95,
            "starting_acu": starting_acu,
            "peak_acu": peak_acu,
            "cluster_scaled": peak_acu > starting_acu,
        },
    }
    return json.dumps(payload, indent=2)
