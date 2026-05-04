# CLAUDE.md — AI-Driven Database Workload Lab

This file steers Claude Code when working in this repository.
Read it at the start of every session and after any significant change.

## What this is

A platform-engineering self-service tool. A developer opens a web UI, describes
a database workload in plain English ("insert 50,000 orders then run some
lookups"), and the platform:

1. Sends the prompt to Bedrock (Claude Sonnet 4.6), which translates intent
   into a structured `WorkloadSpec` (rows, table shape, INSERT/SELECT mix,
   duration).
2. Executes the workload against an Aurora Serverless v2 Postgres cluster
   that auto-scales ACUs under load.
3. Streams per-second metrics (rows/sec, latency p50/p95, current ACU count)
   into DynamoDB; the UI polls and renders a live chart.
4. When the run ends, Bedrock writes a plain-English summary
   ("inserted 50k rows in 47s, p95 latency 12ms, cluster scaled from 0.5 to
   2 ACUs at second 18").

## Who it is for

- **Primary user:** internal application developers who want to load-test a
  workload shape against Postgres without writing scripts. They get a URL,
  type a sentence, get a summary.
- **Secondary user:** the platform team. The tool demonstrates Aurora
  Serverless v2 autoscaling behavior for cost and capacity planning, and is
  itself a reference architecture (VPC, IAM, Bedrock, observability).

## Why this design

- **Aurora Serverless v2** is the centerpiece — it gives us a real, visible
  autoscaling story (ACUs going up under write load) without paying for an
  always-on cluster.
- **Bedrock (Claude Sonnet 4.6) appears in two distinct AI tasks:**
  intent-parsing (prompt → typed `WorkloadSpec`) and
  result-summarization (metrics → human-readable summary). Two roles, one
  model, clearly separated.
- **DynamoDB for metrics**, not Postgres. Per-second writes during the
  workload would compete with the workload itself for Aurora capacity.
  DynamoDB on-demand absorbs the writes cleanly.
- **Lambda inside a VPC**, talking to Aurora over a private security group.
  Closer to real production posture than the RDS Data API shortcut.
- **CloudFront + S3** for the UI. Static, cheap, fast, and adds a real
  CDN/edge piece to the Terraform footprint.

## Core architecture

Browser
  -> CloudFront -> S3 (static UI: index.html + index.js)
        UI calls API
  -> API Gateway HTTP API (CORS scoped to CloudFront domain)
        -> Lambda (Python 3.12, arm64, in VPC private subnets)
              -> SSM Parameter Store (model ID, cluster endpoint, secret ARN, table name)
              -> Secrets Manager (Aurora master credentials)
              -> Bedrock Runtime (Converse API — intent parser + summary writer)
              -> Aurora Serverless v2 Postgres (writer endpoint via psycopg)
              -> DynamoDB table (per-second metrics + final run summaries)

VPC: 2 AZs, 2 public subnets (NAT) + 2 private subnets (Lambda + Aurora)
Aurora SG: ingress 5432 from Lambda SG only.
Lambda SG: egress 5432 to Aurora SG only (plus AWS API egress via NAT or VPC endpoints).

## Non-negotiable rules

- **Never** commit secrets, AWS keys, DB passwords, or hardcoded ARNs/model
  IDs. All config comes from SSM Parameter Store or Secrets Manager and is
  read at Lambda cold start.
- **No wildcard IAM.** Every policy targets specific resource ARNs and
  specific actions. Reaching for `"*"` requires an explicit decision logged
  in `DECISIONS.md`. The one acceptable managed policy is
  `AWSLambdaVPCAccessExecutionRole` (for ENI lifecycle) — call it out in
  comments and `DECISIONS.md`.
- **No `0.0.0.0/0` ingress.** Anywhere. Security groups are tightly scoped
  to other security groups by ID.
- **ARM64 Lambda only.** Build wheels for `manylinux2014_aarch64` in
  `app/scripts/build_lambda_package.sh`. `pydantic_core` and `psycopg[binary]`
  must be the arm64 wheels.
- **Treat Bedrock output as untrusted.** The intent-parser response MUST be
  validated against a Pydantic v2 schema. On validation failure, return 400
  with the raw model output included for debugging — never silently coerce.
- **Bedrock never drives privileged actions.** It produces a `WorkloadSpec`
  and a summary string. It does not pick IAM, run arbitrary SQL, choose
  table names freely (table is constrained to a small allowlist), or call
  other AWS APIs.
- **`maxTokens` = 1024** for both Bedrock calls. Bumping requires justification.
- **Idiomatic HCL.** Modules under `infra/modules/`, environments under
  `infra/envs/`. Files: `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`,
  `backend.tf`, `terraform.tf`. Run `terraform fmt -recursive` before every
  commit.
- **Structured JSON logging** with `request_id`, `route`, `latency_ms`,
  `status`, plus event-specific fields. No bare `print()`.
- **Plan/apply separation in CI.** `terraform plan` on PR (post output as
  comment). `terraform apply` only on merge to `main`, gated by a manual
  approval environment.

## Project conventions

### Python
- Python 3.12, formatted with `ruff format`, linted with `ruff check`.
- Type hints on every public function. `from __future__ import annotations`
  at the top of each module.
- FastAPI for routing, Pydantic v2 for I/O models.
- Mangum as the Lambda -> ASGI adapter.
- Module layout under `app/src/ngx_workload_lab/`:
  - `main.py` — FastAPI routes, Mangum handler, request middleware
  - `bedrock.py` — Converse client + system prompts + Pydantic validation
  - `workload.py` — Aurora connection pool, INSERT/SELECT executor, ACU sampling
  - `storage.py` — DynamoDB put/query helpers
  - `config.py` — SSM/Secrets Manager loader, cached at module import
  - `models.py` — shared Pydantic models (`WorkloadSpec`, `RunRecord`, etc.)
  - `prompts/` — system prompts as `.md` files, loaded at import
- Tests in `app/tests/`, named `test_<module>.py`, run with `pytest`.

### Terraform
- `required_version = ">= 1.9"`. Pin the AWS provider version exactly.
- Every variable: `type` + `description`. Optional variables: `default`.
  Validation blocks on user-facing variables.
- Every output: `description`.
- Resource names are nouns, snake_case, no resource type in the name.
- `default_tags` in the provider config: `Project = "ai-workload-lab"`,
  `Environment`, `ManagedBy = "terraform"`. Every resource inherits.
- Modules: `vpc`, `aurora`, `lambda_api`, `dynamodb`, `static_site`,
  `observability`. Environment composition lives in `infra/envs/dev/`.

### Git
- Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`,
  `ci:`, `test:`.
- Small, atomic commits. One logical change per commit.
- PRs target `main`. Squash-merge.

## Bedrock usage rules

- **Model:** Claude Sonnet 4.6 via inference profile
  `arn:aws:bedrock:us-east-2:990393186825:inference-profile/us.anthropic.claude-sonnet-4-6`.
  Read from SSM at runtime. Never hardcode.
- **API:** `bedrock-runtime.converse()`. Not `invoke_model`.
- **Two roles, two prompts:**
  - `prompts/intent_parser.md` — system prompt that instructs the model to
    return ONLY JSON matching the `WorkloadSpec` schema. Few-shot examples
    inline. Validation in code with Pydantic v2.
  - `prompts/run_summary.md` — system prompt for the post-run summary.
    Constraint: <= 5 sentences, no JSON, no recommendations that imply
    privileged actions.
- **Cost guard:** log `usage.inputTokens` and `usage.outputTokens` on every
  call so we can put a metric filter on it.
- **Failure mode:** if Bedrock fails or returns invalid JSON, the workload
  endpoint returns 502 with a structured error and a stored `RunRecord` in
  state `bedrock_error`. The cluster is not touched.

## Observability

- Lambda: structured logs, X-Ray tracing on, dead-letter SQS for async
  failures, CloudWatch alarm on `Errors >= 1` in 5 min -> SNS.
- Aurora: alarm on `ServerlessDatabaseCapacity` at max for > 2 min -> SNS.
- DynamoDB: on-demand, so we watch `ThrottledRequests` (alarm if > 0).
- One CloudWatch dashboard, Terraformed, covering all of the above plus
  API Gateway 4xx/5xx and Bedrock token usage.

## How to work in this repo (for Claude Code)

1. **Before editing**, read this file and the file you're about to change.
2. **Before writing Terraform**, mentally run `terraform fmt` on what you'd
   produce.
3. **Before declaring done**, run locally:
   - `ruff format app/ && ruff check app/`
   - `cd app && pytest`
   - `cd infra/envs/dev && terraform fmt -check && terraform validate`
4. **When you hit an AWS error**, read the CloudWatch log line first. Don't
   guess at IAM. Read the docs, then the logs, then change code.
5. **When unsure**, stop and ask. A clarifying question is cheaper than a
   rewrite.
6. **When the time pressure tempts you to skip Pydantic validation, hardcode
   an ARN, or open a security group too wide**, surface it instead of doing
   it silently.

## What we are explicitly not building in v1

- **Auth on the UI.** v1 demo URL is unauthenticated behind CloudFront.
  Risk acknowledged in `DECISIONS.md`. v1.5: Cognito or signed URLs.
- **Async workload execution.** v1 runs workloads synchronously in the
  Lambda invocation, capped at 60s. v1.5: Step Functions or SQS.
- **IAM auth for Postgres.** v1 uses Secrets Manager–stored master creds.
  v1.5: IAM auth + per-team DB users.
- **Customer-managed KMS keys.** v1 uses AWS-managed keys. v1.5: CMKs on
  Aurora storage, Secrets Manager secret, DynamoDB table, S3 buckets.
- **Multi-AZ writer / reader replicas.** Single writer for v1.
- **Multi-environment (`dev`/`staging`/`prod`).** Single `dev` environment.
- **Terraform tests (`.tftest.hcl`).** Noted as next step.
- **Remote Terraform state.** Local state for v1 to keep the deploy story
  simple. v1.5: S3 backend + DynamoDB lock + GitHub OIDC role for CI.

## Glossary

- **Run:** one execution of a workload, identified by `run_id` (uuid4).
- **WorkloadSpec:** the validated, typed shape produced by the intent parser.
  Fields: `workload_type` ("insert"|"select"|"mixed"), `row_count` (1..100000),
  `mix_ratio` (0..1, fraction of operations that are SELECT),
  `duration_seconds` (5..60), `table_name` (allowlisted).
- **ACU (Aurora Capacity Unit):** Aurora Serverless v2's scaling unit.
  Visible in `describe_db_clusters -> ServerlessV2ScalingConfiguration` and
  CloudWatch `ServerlessDatabaseCapacity`.
- **Summary:** Bedrock-generated plain-English description of a run,
  <= 5 sentences. Stored on the `RunRecord` once `status = "complete"`.
