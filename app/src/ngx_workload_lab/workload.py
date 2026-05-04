"""Workload executor.

Drives an Aurora Serverless v2 Postgres cluster hard enough that the
demo's headline ("watch ACUs scale") actually fires. Decisions baked in
per ADR-008:
  - Fat ~512-byte JSON payloads on every INSERT (CPU + storage pressure).
  - executemany batches of ~500 rows per call (drives writes/sec).
  - Aggregation SELECTs in mixed mode (CPU pressure on read path).
  - 4 worker threads sharing a connection pool of 4-6 connections (the
    cluster sees concurrent write pressure, not single-stream RPS).
  - duration_seconds is the hard cap; row_count is a target.
  - starting_acu sampled at run start, peak_acu tracked across the run.

ACU is read from CloudWatch metric `ServerlessDatabaseCapacity`. The
metric is published at 1-minute granularity, so within a single 60-second
demo we see at most one or two distinct values. The summary prompt
narrates this honestly (per ADR-008).
"""

from __future__ import annotations

import json
import random
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

from psycopg_pool import ConnectionPool

from ngx_workload_lab.logging_setup import get_logger
from ngx_workload_lab.models import MetricSample, WorkloadSpec

logger = get_logger("ngx_workload_lab.workload")

WORKER_COUNT = 4
INSERT_BATCH_SIZE = 500
POOL_MIN = 4
POOL_MAX = 6


@dataclass
class _SecondBucket:
    latencies_ms: list[float] = field(default_factory=list)
    rows_inserted: int = 0
    selects_done: int = 0
    current_acu: float = 0.0
    lock: threading.Lock = field(default_factory=threading.Lock)


def fetch_db_credentials(secrets_client: Any, secret_arn: str) -> dict[str, str]:
    """Read username and password from the AWS-managed cluster secret.

    The managed secret payload is:
        {"username": "...", "password": "..."}
    Other connection details (host, port, dbname) come from env vars
    (the secret rotates; the topology does not).
    """
    response = secrets_client.get_secret_value(SecretId=secret_arn)
    payload = json.loads(response["SecretString"])
    return {"username": payload["username"], "password": payload["password"]}


def build_dsn(*, host: str, port: int, dbname: str, username: str, password: str) -> str:
    # libpq URI escaping: passwords with reserved chars need URL-encoding.
    # AWS-managed secrets generate alphanumeric+symbols; safe to inline most,
    # but we url-encode defensively.
    from urllib.parse import quote

    safe_user = quote(username, safe="")
    safe_pass = quote(password, safe="")
    return (
        f"postgresql://{safe_user}:{safe_pass}@{host}:{port}/{dbname}"
        f"?sslmode=require&application_name=ngx-workload-lab"
    )


def make_payload() -> str:
    """Generate a JSON payload of approximately 512 bytes.

    Aurora v2 needs *real* row content to drive CPU; a single empty row
    over a single connection won't move the ACU needle. The payload
    contains a small `items` array so SELECT-side aggregations can do
    `jsonb_array_length()` work.
    """
    item_count = random.randint(3, 8)
    items = [
        {
            "sku": f"sku-{random.randint(10_000, 99_999)}",
            "qty": random.randint(1, 12),
            "unit_price_cents": random.randint(99, 9999),
        }
        for _ in range(item_count)
    ]
    payload = {
        "customer_id": f"cust-{random.randint(100_000, 999_999)}",
        "channel": random.choice(["web", "ios", "android", "kiosk"]),
        "currency": random.choice(["USD", "EUR", "GBP"]),
        "items": items,
        "shipping_method": random.choice(["ground", "express", "overnight", "pickup"]),
        "notes": "x" * 80,  # padding to push toward 512B
    }
    return json.dumps(payload)


def ensure_table(pool: ConnectionPool, table_name: str) -> None:
    """Create the workload table if it doesn't exist. Idempotent.

    `table_name` is validated against ALLOWED_TABLE_NAMES upstream
    (WorkloadSpec validator), so it's safe to inject here.
    """
    ddl = f"""
    CREATE TABLE IF NOT EXISTS {table_name} (
        id BIGSERIAL PRIMARY KEY,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(ddl)
        conn.commit()
    logger.info("workload_table_ensured", table=table_name)


def sample_current_acu(cloudwatch_client: Any, cluster_identifier: str) -> float:
    """Read the most recent ServerlessDatabaseCapacity datapoint.

    Returns 0.0 if no datapoint is available (e.g., very new cluster
    before the first metric publish).
    """
    now = datetime.now(UTC)
    response = cloudwatch_client.get_metric_data(
        StartTime=now - timedelta(minutes=5),
        EndTime=now,
        ScanBy="TimestampDescending",
        MetricDataQueries=[
            {
                "Id": "acu",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/RDS",
                        "MetricName": "ServerlessDatabaseCapacity",
                        "Dimensions": [
                            {"Name": "DBClusterIdentifier", "Value": cluster_identifier}
                        ],
                    },
                    "Period": 60,
                    "Stat": "Average",
                },
                "ReturnData": True,
            }
        ],
    )
    values = response["MetricDataResults"][0].get("Values", [])
    return float(values[0]) if values else 0.0


class WorkloadExecutor:
    """Runs a `WorkloadSpec` to completion, capped by `duration_seconds`."""

    def __init__(
        self,
        *,
        spec: WorkloadSpec,
        run_id: str,
        dsn: str,
        cloudwatch_client: Any,
        cluster_identifier: str,
        metric_sink: Any = None,
    ) -> None:
        # metric_sink: optional callable taking a single MetricSample and
        # persisting it. The ACU sampler invokes it on each completed second
        # so the live-streaming UI can poll partial results during the run.
        # When None, metrics only land at the end via _collect_metrics().
        self.spec = spec
        self.run_id = run_id
        self.cluster_identifier = cluster_identifier
        self.cloudwatch = cloudwatch_client
        self.pool = ConnectionPool(
            dsn,
            min_size=POOL_MIN,
            max_size=POOL_MAX,
            open=False,
            timeout=10.0,
        )

        self._buckets: dict[int, _SecondBucket] = defaultdict(_SecondBucket)
        self._buckets_lock = threading.Lock()
        self._counter_lock = threading.Lock()
        self._total_inserted = 0
        self._total_selects = 0

        self.starting_acu = 0.0
        self.peak_acu = 0.0
        self._latest_acu = 0.0

        self._metric_sink = metric_sink
        self._wallclock_start: datetime | None = None
        self._flushed_seconds: set[int] = set()

    def open(self) -> None:
        self.pool.open()
        ensure_table(self.pool, self.spec.table_name)

    def close(self) -> None:
        self.pool.close()

    def __enter__(self) -> WorkloadExecutor:
        self.open()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def run(self) -> tuple[list[MetricSample], float, float, int, int]:
        """Execute the workload. Returns (metrics, starting_acu, peak_acu, rows, selects)."""
        self.starting_acu = sample_current_acu(self.cloudwatch, self.cluster_identifier)
        self._latest_acu = self.starting_acu
        self.peak_acu = self.starting_acu

        start_monotonic = time.monotonic()
        deadline = start_monotonic + self.spec.duration_seconds
        wallclock_start = datetime.now(UTC)
        # Stash so the per-second flusher can stamp MetricSamples with
        # consistent timestamps even though it runs in a worker thread.
        self._wallclock_start = wallclock_start

        logger.info(
            "workload_run_started",
            run_id=self.run_id,
            spec=self.spec.model_dump(),
            starting_acu=self.starting_acu,
        )

        with ThreadPoolExecutor(max_workers=WORKER_COUNT + 1) as pool:
            workers = [
                pool.submit(self._worker_loop, start_monotonic, deadline)
                for _ in range(WORKER_COUNT)
            ]
            sampler = pool.submit(self._acu_sampler_loop, start_monotonic, deadline)
            for f in workers:
                f.result()
            sampler.result()

        metrics = self._collect_metrics(wallclock_start)

        logger.info(
            "workload_run_completed",
            run_id=self.run_id,
            rows_inserted=self._total_inserted,
            selects_done=self._total_selects,
            starting_acu=self.starting_acu,
            peak_acu=self.peak_acu,
        )
        return metrics, self.starting_acu, self.peak_acu, self._total_inserted, self._total_selects

    def _worker_loop(self, start_monotonic: float, deadline: float) -> None:
        rng = random.Random()
        while time.monotonic() < deadline:
            with self._counter_lock:
                if (
                    self._total_inserted >= self.spec.row_count
                    and self.spec.workload_type == "insert"
                ):
                    return

            do_select = self.spec.workload_type == "select" or (
                self.spec.workload_type == "mixed" and rng.random() < self.spec.mix_ratio
            )

            # Selects only make sense once we've inserted something.
            if do_select:
                with self._counter_lock:
                    if self._total_inserted == 0 and self.spec.workload_type == "mixed":
                        do_select = False

            try:
                t0 = time.perf_counter()
                if do_select:
                    self._do_select_aggregation()
                    op = "select"
                    op_units = 1
                else:
                    inserted = self._do_insert_batch(start_monotonic, deadline)
                    op = "insert"
                    op_units = inserted
                latency_ms = (time.perf_counter() - t0) * 1000
            except Exception as e:
                logger.exception("workload_op_failed", error=str(e))
                continue

            second = int(time.monotonic() - start_monotonic)
            bucket = self._bucket(second)
            with bucket.lock:
                bucket.latencies_ms.append(latency_ms)
                if op == "insert":
                    bucket.rows_inserted += op_units
                else:
                    bucket.selects_done += op_units

            with self._counter_lock:
                if op == "insert":
                    self._total_inserted += op_units
                else:
                    self._total_selects += op_units

    def _do_insert_batch(self, start_monotonic: float, deadline: float) -> int:
        with self._counter_lock:
            remaining = max(0, self.spec.row_count - self._total_inserted)
            batch = min(
                INSERT_BATCH_SIZE,
                remaining if self.spec.workload_type == "insert" else INSERT_BATCH_SIZE,
            )
        if batch <= 0:
            return 0

        rows = [(make_payload(),) for _ in range(batch)]
        sql = f"INSERT INTO {self.spec.table_name} (payload) VALUES (%s)"
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.executemany(sql, rows)
            conn.commit()
        return batch

    def _do_select_aggregation(self) -> None:
        # Aggregation forces CPU work on the read path. jsonb_array_length
        # touches every row's payload field — non-trivial.
        sql = (
            f"SELECT count(*), avg(jsonb_array_length(payload->'items'))::float, "
            f"max(created_at) FROM {self.spec.table_name}"
        )
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(sql)
            cur.fetchone()

    def _acu_sampler_loop(self, start_monotonic: float, deadline: float) -> None:
        # Sample once per second. CloudWatch publishes ServerlessDatabaseCapacity
        # at 1-minute granularity, so consecutive samples will frequently match.
        # Cheap to call ($0.01 / 1000 GetMetricData calls) — we tolerate the noise.
        while time.monotonic() < deadline:
            try:
                acu = sample_current_acu(self.cloudwatch, self.cluster_identifier)
                self._latest_acu = acu
                if acu > self.peak_acu:
                    self.peak_acu = acu
            except Exception as e:
                logger.warning("acu_sample_failed", error=str(e))

            current_second = int(time.monotonic() - start_monotonic)
            bucket = self._bucket(current_second)
            with bucket.lock:
                bucket.current_acu = self._latest_acu

            # Flush completed seconds to the metric sink so the UI's
            # poll loop can stream partial results before the run
            # finishes. A bucket is "complete" once a later second has
            # started; we don't flush the current second yet because
            # workers may still be filling it.
            if self._metric_sink is not None:
                self._flush_completed_seconds(current_second)

            time.sleep(1.0)

    def _flush_completed_seconds(self, current_second: int) -> None:
        if self._wallclock_start is None or self._metric_sink is None:
            return
        with self._buckets_lock:
            candidates = sorted(
                s for s in self._buckets if s < current_second and s not in self._flushed_seconds
            )
        for s in candidates:
            sample = self._build_sample(s, self._wallclock_start)
            try:
                self._metric_sink(sample)
                self._flushed_seconds.add(s)
            except Exception as e:
                # Don't crash the run on a transient DDB hiccup; the
                # final put_metric_samples at run end re-writes everything
                # via batch_writer (idempotent on same key) so a missed
                # flush is recovered. Log so it shows up in the run's
                # CloudWatch logs.
                logger.warning("metric_flush_failed", second=s, error=str(e))

    def _build_sample(self, second: int, wallclock_start: datetime) -> MetricSample:
        bucket = self._buckets[second]
        with bucket.lock:
            lats = sorted(bucket.latencies_ms)
            return MetricSample(
                run_id=self.run_id,
                metric_ts=wallclock_start + timedelta(seconds=second),
                second_offset=second,
                rows_inserted=bucket.rows_inserted,
                selects_done=bucket.selects_done,
                p50_latency_ms=_percentile(lats, 50),
                p95_latency_ms=_percentile(lats, 95),
                current_acu=bucket.current_acu,
            )

    def _bucket(self, second: int) -> _SecondBucket:
        with self._buckets_lock:
            return self._buckets[second]

    def _collect_metrics(self, wallclock_start: datetime) -> list[MetricSample]:
        with self._buckets_lock:
            seconds = sorted(self._buckets.keys())
        return [self._build_sample(s, wallclock_start) for s in seconds]


def _percentile(sorted_values: list[float], pct: int) -> float:
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return round(sorted_values[0], 2)
    k = (len(sorted_values) - 1) * (pct / 100.0)
    lower = int(k)
    upper = min(lower + 1, len(sorted_values) - 1)
    frac = k - lower
    return round(sorted_values[lower] * (1 - frac) + sorted_values[upper] * frac, 2)
