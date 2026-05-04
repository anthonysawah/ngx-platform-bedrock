from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    """Lambda config loaded once at cold start.

    For v1 these come from environment variables set by the lambda_api Terraform
    module. The variables themselves resolve from SSM Parameter Store at deploy
    time (see infra/envs/dev/main.tf SSM resources). We deliberately avoid
    runtime SSM calls in the request path.
    """

    aws_region: str
    environment: str
    bedrock_model_id: str
    aurora_cluster_identifier: str
    aurora_cluster_endpoint: str
    aurora_secret_arn: str
    aurora_database_name: str
    aurora_port: int
    dynamodb_table_name: str
    log_level: str

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            aws_region=_required("AWS_REGION"),
            environment=_required("APP_ENVIRONMENT"),
            bedrock_model_id=_required("BEDROCK_MODEL_ID"),
            aurora_cluster_identifier=_required("AURORA_CLUSTER_IDENTIFIER"),
            aurora_cluster_endpoint=_required("AURORA_CLUSTER_ENDPOINT"),
            aurora_secret_arn=_required("AURORA_SECRET_ARN"),
            aurora_database_name=_required("AURORA_DATABASE_NAME"),
            aurora_port=int(_required("AURORA_PORT")),
            dynamodb_table_name=_required("DYNAMODB_TABLE_NAME"),
            log_level=os.environ.get("LOG_LEVEL", "INFO"),
        )


def _required(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise RuntimeError(f"Required environment variable {key!r} is not set.")
    return value
