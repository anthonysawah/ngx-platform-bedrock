# CLAUDE.md — NGX Platform Bedrock

This file steers Claude Code when working in this repository.
Read it at the start of every session and after any significant change.

## What this is

An internal developer platform service that lets engineers run AWS account
audits and get plain-English summaries powered by Amazon Bedrock (Claude
Sonnet 4.6). The audience is platform consumers — application engineers
who want answers, not raw JSON dumps from the AWS API.

This is v2 of an NGX coding challenge. v1 lives at
github.com/anthonysawah/ngx-platform-automation and is the MVP. This repo
adds the AI layer (Bedrock summarization), tighter security posture, and
production-grade Terraform.

## Core architecture
Client (curl / UI)
│  HTTPS
▼
API Gateway (HTTP API)
│
▼
Lambda (Python 3.12, arm64)         ← FastAPI via Mangum adapter
├── boto3 → S3 (audit calls: GetEncryptionConfiguration, GetPublicAccessBlock)
├── boto3 → Bedrock Runtime (Converse API → Claude Sonnet 4.6 inference profile)
└── boto3 → DynamoDB (audit + summary persistence, on-demand billing)
Config: SSM Parameter Store (model ID, table name, audited bucket list)
Observability: structured JSON logs → CloudWatch → metric filter → alarm → SNS

## Non-negotiable rules

- **Never** commit secrets, AWS access keys, or the Bedrock model ID hardcoded.
  All config comes from SSM Parameter Store, read at Lambda cold start.
- **No wildcard IAM.** Every IAM policy is scoped to specific resource ARNs and
  specific actions. If you reach for `"*"`, stop and ask.
- **ARM64 Lambda only.** Build wheels for `manylinux2014_aarch64` in
  `app/scripts/build_lambda_package.sh`. Pydantic and friends will not work
  with x86_64 wheels on an arm64 runtime — this was a real bug in v1.
- **Idiomatic HCL.** Modules under `infra/modules/`, environments under
  `infra/envs/`. Files: `main.tf`, `variables.tf`, `outputs.tf`,
  `providers.tf`, `backend.tf`, `terraform.tf`. Run `terraform fmt -recursive`
  before every commit.
- **Structured logging.** Every log line is JSON with `request_id`, `route`,
  `latency_ms`, `status`, plus event-specific fields. Use `structlog` or
  `aws-lambda-powertools`. No bare `print()`, no `f"…"` log strings.
- **Plan/apply separation in CI.** `terraform plan` runs on PR and posts
  the plan as a comment. `terraform apply` only runs on merge to `main`,
  gated by a manual approval environment in GitHub Actions.

## Project conventions

### Python
- Python 3.12, formatted with `ruff format`, linted with `ruff check`.
- Type hints on every public function. `from __future__ import annotations`
  at the top of each module.
- FastAPI for the route layer, Pydantic v2 for request/response models.
- Mangum for the Lambda → ASGI adapter.
- One module per concern: `main.py` (routes), `bedrock.py` (Bedrock client +
  prompts), `audit.py` (AWS audit logic), `storage.py` (DynamoDB I/O),
  `config.py` (SSM Parameter Store loader, cached).
- Tests in `app/tests/`, named `test_<module>.py`, run with `pytest`.

### Terraform
- Pin all providers in `terraform.tf` with `required_version = ">= 1.9"`
  and exact provider versions.
- Every variable has a `type` and `description`. Optional variables have
  a `default`. Validation blocks on anything user-facing.
- Every output has a `description`.
- Resource names are nouns, snake_case, no resource type in the name
  (`resource "aws_dynamodb_table" "audits"`, not `"audits_table"`).
- Tags applied via a `default_tags` block in the provider config. Every
  resource inherits `Project`, `Environment`, `ManagedBy = "terraform"`.

### Git
- Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `ci:`.
- Small, atomic commits. One logical change per commit.
- PRs target `main`. Squash-merge.

## Bedrock usage rules

- **Model:** Claude Sonnet 4.6 via inference profile
  `arn:aws:bedrock:us-east-2:990393186825:inference-profile/us.anthropic.claude-sonnet-4-6`.
  Read from SSM, never hardcode.
- **API:** `bedrock-runtime.converse()`. Not `invoke_model` — Converse is the
  current best practice and works uniformly across Anthropic / Nova / Mistral.
- **maxTokens:** 1024 for summaries. Bumping this without a reason is a code-review
  blocker.
- **System prompt:** Lives in `app/src/ngx_bedrock/prompts/audit_summary.md`,
  not inline in Python. Loaded at module import.
- **Safety:** Treat Bedrock output as untrusted. Never feed Bedrock output back
  into another tool call without validation. Never let it influence IAM, DB
  writes, or downstream API calls in v1 — its only job is summarizing.
- **Cost guard:** Log token usage on every call (`usage.inputTokens`,
  `usage.outputTokens`) so we can put a CloudWatch metric on it later.

## How to work in this repo (instructions for Claude Code)

1. **Before editing**, read this file and the file you're about to change.
2. **Before writing Terraform**, run `terraform fmt` mentally on what you'd
   produce — match the style guide.
3. **Before declaring done**, run locally:
   - `ruff format app/ && ruff check app/`
   - `cd app && pytest`
   - `cd infra/envs/dev && terraform fmt -check && terraform validate`
4. **When you hit an AWS error**, read the CloudWatch log line first. Don't
   guess at IAM. v1 lost 30 minutes because we assumed `s3:GetBucketEncryption`
   was the IAM action — it's actually `s3:GetEncryptionConfiguration`. Read
   the docs, then the logs, then change code.
5. **When unsure**, stop and ask. A clarifying question is cheaper than a
   rewrite.

## What we are explicitly not building in v1

- Multi-environment (`dev`/`staging`/`prod`) — single `dev` env only.
- Customer-managed KMS keys — `aws/dynamodb` and `aws/lambda` AWS-managed
  keys are acceptable for v1, with a `DECISIONS.md` note on the upgrade path.
- Bedrock Agents or multi-step tool use — single Converse call per request.
- A frontend UI — curl + screenshots are sufficient for the demo. UI is a
  v1.5 stretch goal hosted on S3 + CloudFront.
- Aurora Serverless — DynamoDB is the right shape for our access pattern
  (key-value reads of past audit results by ID and timestamp).

## Glossary

- **v1 / MVP repo:** `github.com/anthonysawah/ngx-platform-automation`. Working,
  deployed, separate from this codebase.
- **Audit:** A read-only inspection of AWS resources. Currently: S3 default
  encryption + public access block. Extensible by adding handlers in `audit.py`.
- **Summary:** Bedrock-generated plain-English description of an audit result,
  ≤ 5 sentences, suitable for posting to Slack or a ticket.
