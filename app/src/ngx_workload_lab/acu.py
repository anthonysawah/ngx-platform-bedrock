"""Aurora ACU series, read at API time instead of sampled during the run.

The executor Lambda lost its internet path in the no-NAT refactor (ADR-013),
so it can no longer call CloudWatch. Instead the API Lambda pulls the whole
`ServerlessDatabaseCapacity` series for a run's time window and overlays it
onto the per-second metric rows when serving GET /workloads/{run_id}.

This is strictly *more* honest than the old approach. Previously the
executor polled CloudWatch once a second and stamped whatever it got onto
that second's row — but CloudWatch only publishes ACU once a minute, so
~59 of every 60 rows carried a stale repeat presented as a fresh reading.
Fetching the real series and mapping each row to its nearest datapoint
shows the same underlying data without implying per-second resolution we
never had.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

from ngx_workload_lab.models import MetricSample

# CloudWatch publishes ServerlessDatabaseCapacity at 60s. Requesting a finer
# period just returns sparser data, so ask for exactly what exists.
ACU_PERIOD_SECONDS = 60


def fetch_acu_series(
    cloudwatch_client: Any,
    cluster_identifier: str,
    start: datetime,
    end: datetime,
) -> list[tuple[datetime, float]]:
    """Return [(timestamp, acu)] ascending for the window, or [] if none."""
    # Widen slightly: a run shorter than the publish interval can otherwise
    # fall entirely between two datapoints and return nothing.
    response = cloudwatch_client.get_metric_data(
        StartTime=start - timedelta(minutes=2),
        EndTime=end + timedelta(minutes=2),
        ScanBy="TimestampAscending",
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
                    "Period": ACU_PERIOD_SECONDS,
                    "Stat": "Average",
                },
                "ReturnData": True,
            }
        ],
    )
    result = response["MetricDataResults"][0]
    stamps = result.get("Timestamps", [])
    values = result.get("Values", [])
    series = [
        (t if t.tzinfo else t.replace(tzinfo=UTC), float(v))
        for t, v in zip(stamps, values, strict=False)
    ]
    series.sort(key=lambda p: p[0])
    return series


def overlay_acu(
    metrics: list[MetricSample], series: list[tuple[datetime, float]]
) -> list[MetricSample]:
    """Stamp each metric sample with the ACU datapoint nearest its timestamp."""
    if not series or not metrics:
        return metrics

    out: list[MetricSample] = []
    for m in metrics:
        ts = m.metric_ts if m.metric_ts.tzinfo else m.metric_ts.replace(tzinfo=UTC)
        nearest = min(series, key=lambda p: abs((p[0] - ts).total_seconds()))
        out.append(m.model_copy(update={"current_acu": nearest[1]}))
    return out


def summarize_series(series: list[tuple[datetime, float]]) -> tuple[float, float]:
    """Return (starting_acu, peak_acu) for a run's window."""
    if not series:
        return 0.0, 0.0
    values = [v for _, v in series]
    return values[0], max(values)
