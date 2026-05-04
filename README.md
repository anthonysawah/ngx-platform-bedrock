# AI-Driven Database Workload Lab

A platform-engineering self-service tool. A developer types **"insert
50,000 orders and read some back"** in a web UI, and the platform:

1. Sends the prompt to **Bedrock (Claude Sonnet 4.6)**, which translates
   intent into a typed `WorkloadSpec` (rows, table, INSERT/SELECT mix,
   duration).
2. Executes the workload against an **Aurora Serverless v2 Postgres**
   cluster that auto-scales ACUs under load.
3. Streams per-second metrics (rows/sec, p50/p95 latency, current ACU)
   into **DynamoDB** for the UI to chart.
4. Calls Bedrock a second time to write a plain-English summary of what
   actually happened — including an honest "the cluster did not scale"
   when no scaling happened.

**Live demo:** https://d333zl5hz71w0e.cloudfront.net

> ![Workload Lab UI](docs/screenshots/ui.png)
>
> *Screenshot to be added — open the live demo and run "do a quick
> mixed workload for 10 seconds" to see the chart and summary.*

---

## Why this exists

The same prompt + summary pattern shows up in many places (intent
parser, run summary). What's interesting is the rest of the platform
around it:

- **Aurora Serverless v2** is the centerpiece. The demo's headline is
  watching ACUs rise under load and fall back down again.
- **Two Bedrock roles, one model**, clearly separated:
  intent-parsing (prompt → typed spec) and result-summarization
  (metrics → human-readable summary).
- **DynamoDB for metrics**, not Postgres. Per-second writes during a
  workload should not compete with the workload itself for Aurora
  capacity. DynamoDB on-demand absorbs them cleanly.
- **Lambda inside a VPC**, talking to Aurora over a private security
  group on 5432 — closer to real production posture than the RDS Data
  API shortcut.
- **CloudFront + S3** for the UI, with Origin Access Control + a private
  bucket.

The output is also a **reference architecture** for the platform team:
VPC, IAM least-privilege, Bedrock-with-validation, observability,
Terraform modules.

---

## Architecture

![Architecture diagram](diagrams/architecture.png)

```
Browser
  └─> CloudFront ─> S3 (private, OAC)            static UI
        UI calls API
  └─> API Gateway HTTP API                       CORS scoped to CloudFront
        └─> Lambda (Python 3.12 / arm64, in VPC private subnets)
              ├─> SSM Parameter Store           model id, cluster id, table name
              ├─> Secrets Manager               AWS-managed Aurora master secret
              ├─> Bedrock Runtime               Converse — intent parser + summary
              ├─> Aurora Serverless v2 Postgres writer endpoint via psycopg
              └─> DynamoDB                      run header + per-second metrics

VPC: 10.20.0.0/16, 2 AZs, 2 public + 2 private subnets, single NAT.
SGs:   Lambda → Aurora 5432 only; Lambda → 0.0.0.0/0 443 only (NAT).
       Aurora ingress 5432 from Lambda SG only. No 0.0.0.0/0 ingress.
Gateway endpoints: S3 + DynamoDB (free; off the NAT path).
```

[`DECISIONS.md`](DECISIONS.md) records every non-obvious choice with
reasoning and v1.5 migration paths.

---

## Stack

| Layer        | Technology                                                                  |
| ------------ | --------------------------------------------------------------------------- |
| UI           | Static HTML + vanilla JS + Chart.js, served by CloudFront                   |
| API          | API Gateway HTTP API ($default route → Lambda)                              |
| Service      | Python 3.12 / FastAPI / Pydantic v2 / Mangum, on Lambda arm64               |
| Workload     | psycopg 3 + psycopg_pool (4–6 conns), 4 worker threads, 500-row executemany |
| AI           | Bedrock Converse, Claude Sonnet 4.6 via inference profile (us.\*)           |
| Database     | Aurora Serverless v2 Postgres 15.17, AWS-managed master credentials         |
| Metrics      | DynamoDB on-demand, sparse GSI on status                                    |
| Config       | SSM Parameter Store + Secrets Manager (no secrets in TF state)              |
| Observability| CloudWatch alarms + dashboard, SNS email, X-Ray, structlog JSON             |
| Infra        | Terraform 1.9+ / AWS provider 5.100.0, local state                          |
| CI           | GitHub Actions (ruff, pytest, fmt + validate, plan on PR, apply on main)    |

---

## Repository layout

```
.
├── CLAUDE.md                     project conventions and rules
├── DECISIONS.md                  ADRs: every non-obvious choice + v1.5 path
├── README.md                     this file
├── diagrams/                     architecture diagram source + PNG
├── app/
│   ├── pyproject.toml            Python deps, ruff + pytest config
│   ├── src/ngx_workload_lab/     service code
│   │   ├── main.py               FastAPI routes + Mangum handler
│   │   ├── bedrock.py            Converse: parse_intent + summarize_run
│   │   ├── workload.py           pool, executor, ACU sampling
│   │   ├── storage.py            DynamoDB persistence
│   │   ├── config.py             cold-start env loader
│   │   ├── models.py             Pydantic schemas + table allowlist
│   │   ├── logging_setup.py      structlog JSON config
│   │   └── prompts/              .md system prompts
│   ├── tests/                    pytest unit tests (16)
│   ├── ui/                       index.html / styles.css / index.js
│   └── scripts/
│       ├── build_lambda_package.sh   manylinux2014_aarch64 zip build
│       └── deploy_ui.sh              S3 sync + CloudFront invalidation
├── infra/
│   ├── envs/dev/                 environment composition + SSM params
│   └── modules/
│       ├── vpc/                  2 AZ + NAT + gateway endpoints
│       ├── aurora/               Serverless v2 Postgres
│       ├── lambda_api/           Lambda + HTTP API + IAM least-privilege
│       ├── dynamodb/             runs table + GSI
│       ├── static_site/          S3 + CloudFront + OAC
│       └── observability/        SNS + alarms + dashboard
└── .github/workflows/            CI + deploy-dev pipelines
```

---

## Deploy from scratch

### Prerequisites

- AWS account with **Pay-As-You-Go** billing (Aurora cluster creation
  is blocked on the AWS Free Plan; see DECISIONS ADR-003).
- AWS region `us-east-2` with Bedrock Claude Sonnet 4.6 inference
  profile access enabled in the console.
- `terraform >= 1.9`, `python 3.12`, `uv`, `aws` CLI configured with
  credentials.

### 1. Build the Lambda zip

```bash
uv venv --python 3.12 app/.venv
uv pip install --python app/.venv/bin/python -e "app[dev]"
app/.venv/bin/python -m ensurepip --upgrade
bash app/scripts/build_lambda_package.sh
# → app/build/lambda.zip (verifies arm64 only)
```

### 2. Apply infrastructure

```bash
cd infra/envs/dev
terraform init
terraform apply -var=alarm_email=you@example.com
# Approves and creates ~50 resources. Aurora cluster takes ~5 min.
# Watch your inbox for the SNS subscription confirmation.
```

Outputs include `api_endpoint`, `ui_url`, `dashboard_url`,
`alerts_sns_topic_arn`.

### 3. Deploy the UI

```bash
bash app/scripts/deploy_ui.sh dev
# Substitutes the API URL into config.js, syncs to S3, invalidates CloudFront.
```

### 4. Try it

- Visit `ui_url` from the Terraform outputs.
- Type a prompt: **"do a quick mixed workload for 10 seconds"**.
- Watch the chart render once Bedrock summarizes (sync request, ~12 s).

Or via curl:

```bash
curl -X POST "$API_URL/workloads" \
  -H 'content-type: application/json' \
  -d '{"prompt":"do a quick mixed workload for 10 seconds"}'
```

### 5. Iterate

- Edit `app/src/ngx_workload_lab/`, run `pytest` and `ruff check`.
- Rebuild the zip: `bash app/scripts/build_lambda_package.sh`.
- Re-apply: `terraform apply -var=alarm_email=...` (Lambda updates
  in-place via the new `source_code_hash`).
- For UI changes: `bash app/scripts/deploy_ui.sh dev`.

---

## Teardown

```bash
cd infra/envs/dev
terraform destroy -var=alarm_email=you@example.com
```

Notes:

- Empty the UI S3 bucket first if versioning has any objects in non-current versions: `aws s3 rm s3://<bucket> --recursive` and delete versions via the console (the bucket has versioning on per the static_site module).
- The Aurora master secret has a 7-day recovery window after `terraform destroy`. The legacy custom secret created by ADR-007's phase-1 transition has been removed already.
- `terraform destroy` does **not** remove SNS subscription confirmations — that's an inbox-side click.

---

## What's next (v1.5)

Documented in `DECISIONS.md` under "v1.5 migration path" sections:

| ADR | Decision                                                | v1.5 migration                                                            |
| --- | ------------------------------------------------------- | ------------------------------------------------------------------------- |
| 002 | Local Terraform state                                   | S3 backend + DynamoDB lock + GitHub OIDC role                             |
| 003 | Operate as account root                                 | Named IAM user + MFA + OIDC role for CI                                   |
| 005 | Gateway VPC endpoints only                              | Add interface endpoints (SSM, Secrets Manager, Bedrock Runtime)           |
| 008 | row_count is target, duration is hard cap (5..20 in v1) | Step Functions / SQS for async workloads → 5..3600s                       |
| 009 | Synchronous request path capped by API GW 30s          | Async kickoff returning 202 + run_id; UI polls /workloads/{run_id}        |

Other v1.5 items not yet ADR'd:

- Customer-managed KMS keys on Aurora storage, Secrets Manager, DDB, S3.
- IAM auth for Postgres, per-team DB users.
- Multi-AZ writer + reader replicas.
- Multi-environment (`staging`, `prod`).
- Terraform tests (`.tftest.hcl`).
- Cognito or signed CloudFront URLs in front of the UI.

---

## License

Proprietary. Internal lab project.
