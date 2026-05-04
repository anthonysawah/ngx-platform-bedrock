from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

WorkloadType = Literal["insert", "select", "mixed"]
RunStatus = Literal[
    "pending",
    "running",
    "complete",
    "bedrock_error",
    "workload_error",
    "timeout",
]

# Tables the workload executor is allowed to touch. Anything outside this
# set is rejected at WorkloadSpec validation, not interpreted at SQL build
# time. Keeps Bedrock from picking arbitrary table names.
ALLOWED_TABLE_NAMES: frozenset[str] = frozenset({"workload_orders"})


class WorkloadSpec(BaseModel):
    """Validated, typed shape of an intent prompt.

    Bedrock returns most of this. `duration_seconds` is the hard cap;
    `row_count` is a target the executor tries to hit but does not
    exceed the duration budget for. See DECISIONS.md ADR-008.

    Honest-clamp fields (ADR-011):
      - `original_prompt`: the user's verbatim text. Server-set after
        Bedrock returns. Default empty so Bedrock outputs without it
        validate cleanly.
      - `clamp_notes`: Bedrock-set when it clamped any field away from
        the user's stated number. None when the spec matched the ask.
    """

    model_config = ConfigDict(extra="forbid")

    workload_type: WorkloadType
    row_count: int = Field(ge=1, le=100_000)
    mix_ratio: float = Field(ge=0.0, le=1.0, default=0.3)
    duration_seconds: int = Field(ge=5, le=180)
    table_name: str

    original_prompt: str = ""
    clamp_notes: str | None = None

    @field_validator("table_name")
    @classmethod
    def _table_name_in_allowlist(cls, v: str) -> str:
        if v not in ALLOWED_TABLE_NAMES:
            raise ValueError(
                f"table_name must be one of {sorted(ALLOWED_TABLE_NAMES)!r}; got {v!r}"
            )
        return v


class WorkloadRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    prompt: str = Field(min_length=1, max_length=2_000)


class WorkloadCreated(BaseModel):
    run_id: str
    status: RunStatus
    spec: WorkloadSpec | None = None


class RunRecord(BaseModel):
    """Persisted in DynamoDB. Keys: PK=run_id, SK=metric_ts (per-second metric rows
    use the same PK with a real timestamp; the run header row uses metric_ts="run").
    """

    model_config = ConfigDict(extra="ignore")

    run_id: str
    status: RunStatus
    spec: WorkloadSpec | None = None
    created_at: datetime
    updated_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None

    rows_completed: int = 0
    selects_completed: int = 0

    starting_acu: float | None = None
    peak_acu: float | None = None

    summary: str | None = None
    error: str | None = None
    bedrock_input_tokens: int | None = None
    bedrock_output_tokens: int | None = None


class MetricSample(BaseModel):
    """One per-second sample written during a run."""

    model_config = ConfigDict(extra="ignore")

    run_id: str
    metric_ts: datetime
    second_offset: int
    rows_inserted: int
    selects_done: int
    p50_latency_ms: float
    p95_latency_ms: float
    current_acu: float
