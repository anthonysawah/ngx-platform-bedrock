from __future__ import annotations

import json
from unittest.mock import Mock

from ngx_workload_lab.workload import (
    _percentile,
    build_dsn,
    fetch_db_credentials,
    make_payload,
    sample_current_acu,
)


def test_make_payload_is_around_512_bytes_and_valid_json() -> None:
    seen_sizes = []
    for _ in range(50):
        text = make_payload()
        seen_sizes.append(len(text.encode("utf-8")))
        decoded = json.loads(text)
        assert "items" in decoded
        assert 3 <= len(decoded["items"]) <= 8
        assert decoded["channel"] in {"web", "ios", "android", "kiosk"}

    avg = sum(seen_sizes) / len(seen_sizes)
    # Loose bounds — payload size varies with random item count.
    # The intent is "non-trivial size", not exactly 512.
    assert 350 <= avg <= 800, f"unexpected avg payload size: {avg}"


def test_build_dsn_url_encodes_special_chars() -> None:
    dsn = build_dsn(
        host="cluster.example.com",
        port=5432,
        dbname="workload",
        username="admin",
        password="p@ss/word#1",
    )
    assert dsn.startswith("postgresql://admin:p%40ss%2Fword%231@cluster.example.com:5432/workload")
    assert "sslmode=require" in dsn
    assert "application_name=ngx-workload-lab" in dsn


def test_fetch_db_credentials_reads_aws_managed_secret_shape() -> None:
    secrets = Mock()
    secrets.get_secret_value.return_value = {
        "SecretString": json.dumps({"username": "workload_admin", "password": "secret-xyz"}),
    }
    creds = fetch_db_credentials(secrets, "arn:aws:secretsmanager:...:secret:rds!cluster-abc-XYZ")
    assert creds == {"username": "workload_admin", "password": "secret-xyz"}
    secrets.get_secret_value.assert_called_once_with(
        SecretId="arn:aws:secretsmanager:...:secret:rds!cluster-abc-XYZ"
    )


def test_sample_current_acu_returns_latest_value() -> None:
    cw = Mock()
    cw.get_metric_data.return_value = {"MetricDataResults": [{"Values": [1.5, 1.0, 0.5]}]}
    assert sample_current_acu(cw, "cluster-id") == 1.5

    args = cw.get_metric_data.call_args.kwargs
    assert args["ScanBy"] == "TimestampDescending"
    q = args["MetricDataQueries"][0]
    assert q["MetricStat"]["Metric"]["Namespace"] == "AWS/RDS"
    assert q["MetricStat"]["Metric"]["MetricName"] == "ServerlessDatabaseCapacity"
    assert q["MetricStat"]["Metric"]["Dimensions"][0]["Value"] == "cluster-id"


def test_sample_current_acu_returns_zero_when_no_datapoints() -> None:
    cw = Mock()
    cw.get_metric_data.return_value = {"MetricDataResults": [{"Values": []}]}
    assert sample_current_acu(cw, "cluster-id") == 0.0


def test_percentile_basic() -> None:
    assert _percentile([], 50) == 0.0
    assert _percentile([10.0], 95) == 10.0
    assert _percentile([1.0, 2.0, 3.0, 4.0, 5.0], 50) == 3.0
    # 95th percentile of 1..5: interpolated between 4 and 5
    assert _percentile([1.0, 2.0, 3.0, 4.0, 5.0], 95) == 4.8
