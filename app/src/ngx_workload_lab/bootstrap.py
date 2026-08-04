"""One-time IAM database authentication bootstrap.

Aurora IAM auth requires a database role that has been granted `rds_iam`.
That grant can only be issued over an authenticated SQL connection, so it
has to run from inside the VPC while the master-password path still works.

Deliberately creates a *separate* `workload_app` role rather than granting
`rds_iam` to the master user: in Postgres, granting `rds_iam` to a role
disables password authentication for that role. Doing it to `workload_admin`
would destroy break-glass admin access to the cluster.

Invoked via the Lambda handler with {"_ngx_bootstrap": true}. Idempotent —
safe to run repeatedly.
"""

from __future__ import annotations

from typing import Any

import boto3
import psycopg

from ngx_workload_lab.logging_setup import get_logger

logger = get_logger("ngx_workload_lab.bootstrap")

APP_DB_USER = "workload_app"

# Idempotent. CREATE ROLE has no IF NOT EXISTS in Postgres, hence the DO block.
# PG15 removed the implicit CREATE grant on schema public, so it's explicit here
# (the executor calls CREATE TABLE IF NOT EXISTS on every run).
BOOTSTRAP_SQL = f"""
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{APP_DB_USER}') THEN
        CREATE ROLE {APP_DB_USER} LOGIN;
    END IF;
END
$$;

GRANT rds_iam TO {APP_DB_USER};
GRANT CONNECT ON DATABASE workload TO {APP_DB_USER};
GRANT USAGE, CREATE ON SCHEMA public TO {APP_DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO {APP_DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO {APP_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO {APP_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO {APP_DB_USER};
"""


def generate_iam_token(host: str, port: int, user: str, region: str) -> str:
    """Mint a 15-minute RDS IAM auth token.

    This is local SigV4 signing over the caller's ambient credentials — it
    makes no network call. That property is what lets the executor Lambda
    run in a private subnet with no NAT, no interface endpoint, and no
    Secrets Manager reachability.
    """
    rds = boto3.client("rds", region_name=region)
    return rds.generate_db_auth_token(DBHostname=host, Port=port, DBUsername=user, Region=region)


def run_bootstrap(
    *,
    host: str,
    port: int,
    dbname: str,
    master_user: str,
    master_password: str,
    region: str,
) -> dict[str, Any]:
    """Create the IAM role, grant privileges, then prove IAM auth works.

    Returns a report dict. Raises on failure so the caller surfaces it.
    """
    report: dict[str, Any] = {"grants_applied": False, "iam_auth_verified": False}

    # Phase 1 — grant, using the master password path that works today.
    master_dsn = (
        f"host={host} port={port} dbname={dbname} "
        f"user={master_user} password={master_password} sslmode=require"
    )
    with psycopg.connect(master_dsn, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute(BOOTSTRAP_SQL)
    report["grants_applied"] = True
    logger.info("bootstrap_grants_applied", db_user=APP_DB_USER)

    # Phase 2 — the actual gate. Connect as the IAM role using a signed token
    # instead of a password, and run real SQL. If this fails, the whole
    # no-NAT refactor is not viable.
    token = generate_iam_token(host, port, APP_DB_USER, region)
    iam_dsn = (
        f"host={host} port={port} dbname={dbname} "
        f"user={APP_DB_USER} password={token} sslmode=require"
    )
    with psycopg.connect(iam_dsn, autocommit=True) as conn, conn.cursor() as cur:
        cur.execute("SELECT current_user, version()")
        row = cur.fetchone()
        report["connected_as"] = row[0] if row else None
        report["server_version"] = row[1].split(",")[0] if row and row[1] else None

        # Prove write capability too — a read-only success would be a false pass,
        # since the executor's whole job is INSERT/UPDATE.
        cur.execute(
            "CREATE TABLE IF NOT EXISTS _iam_auth_probe (id int PRIMARY KEY, at timestamptz DEFAULT now())"
        )
        cur.execute(
            "INSERT INTO _iam_auth_probe (id) VALUES (1) "
            "ON CONFLICT (id) DO UPDATE SET at = now()"
        )
        cur.execute("SELECT count(*) FROM _iam_auth_probe")
        probe = cur.fetchone()
        report["write_probe_rows"] = probe[0] if probe else None
        cur.execute("DROP TABLE _iam_auth_probe")

    report["iam_auth_verified"] = True
    report["token_length"] = len(token)
    logger.info("bootstrap_iam_auth_verified", **{k: v for k, v in report.items()})
    return report
