# Architecture Decision Record

Decisions are recorded in chronological order. Each entry: context, decision,
consequences, and (where applicable) the v1.5 migration path.

---

## ADR-001 — AWS provider pin: hashicorp/aws 5.100.0

**Context.** Terraform requires a provider version. Floating ranges
(`~> 5.0`) re-resolve at every `init` and have surprised teams when a minor
release introduced a regression on a Friday afternoon.

**Decision.** Pin AWS provider exactly to `5.100.0`, the head of the 5.x line
at the time of bootstrap. Pin `hashicorp/random` to `3.6.3`. Bumps are
deliberate and recorded as new ADR entries.

**Alternatives considered.**
- `~> 5.0` (any 5.x minor): re-resolves on each `init`, exactly the
  scenario we're avoiding.
- `~> 5.100`: pessimistic on patch. Better than `~> 5.0`, still allows
  silent patch bumps. Rejected — patch releases have caused regressions.
- Drop the `random` pin: it's only used by Aurora's `random_password` in
  early versions of the module. After ADR-007 we no longer need it, but
  it's pinned for clarity if anyone reverts that refactor.

**Consequences.** `terraform init` is reproducible. CI cannot drift onto a
new minor without a code change. The `.terraform.lock.hcl` file is committed
(see also ADR-002).

---

## ADR-002 — Terraform state stays local for v1

**Context.** Production Terraform setups use a remote backend with locking.
For a one-day demo on a personal account with one operator, the operational
cost of bootstrapping S3 + DynamoDB + IAM-for-CI exceeds the benefit.

**Decision.** Use the default `local` backend for v1. Commit
`.terraform.lock.hcl` so provider checksums are reproducible across machines.

**Alternatives considered.**
- S3 + DynamoDB lock from day one: the right answer for any team or any
  environment with more than one operator. Skipped only because it adds
  ~30 minutes of bootstrap (bucket, lock table, IAM, OIDC role) for a
  one-day demo.
- Terraform Cloud free tier: would solve state and locking together.
  Adds an external SaaS dependency that the v1.5 OIDC plan would need
  to revisit anyway.

**Consequences.** No concurrent applies. State lives on the operator's
machine — destroy or migrate before deleting the worktree. Risk is acceptable
for a single-operator demo environment.

**v1.5 migration path.**
1. Create `tf-state-ai-workload-lab` S3 bucket (versioned, default-encrypted,
   public access blocked).
2. Create `tf-state-lock-ai-workload-lab` DynamoDB table with `LockID` PK.
3. Create GitHub OIDC provider + per-repo deploy role with least-privilege
   trust policy.
4. Switch `backend "local"` to `backend "s3"` with `dynamodb_table = ...`.
5. `terraform init -migrate-state` from the operator's machine once.

---

## ADR-003 — Operate as the AWS account root for v1

**Context.** AWS best practice is to never use the account root user for
day-to-day work. Root credentials carry every permission and are not
recoverable from a compromise. The challenge runs on a personal account
where the operator is the only user, and root is what's already configured.

**Decision.** Accept root usage for the v1 deploy of this demo. Do not store
root credentials anywhere outside the operator's local credentials file.
Don't share root access keys.

**Alternatives considered.**
- Provision an `admin` IAM user before any other Terraform: the textbook
  answer. Adds ~15 minutes of yak-shaving (user, MFA, access keys, CLI
  reconfigure) for a one-day single-operator demo.
- IAM Identity Center / SSO: cleanest long-term path, requires Identity
  Center setup which is its own project. Lined up as the v1.5 migration.

**Consequences.** Audit trail attributes every action to the root principal
rather than a named user. This is fine for a personal demo and unacceptable
for a real production posture.

**v1.5 migration path.**
1. Provision a named IAM user with MFA for human/interactive access.
2. Provision a separate IAM role with GitHub OIDC trust for CI deploys
   (see ADR-002 v1.5 migration).
3. Disable the account root user's access keys and lock root behind MFA
   only used for break-glass billing/account-level changes.
4. Re-run `aws sts get-caller-identity` and confirm the principal is the
   named IAM user, not root.

---

## ADR-004 — `AWSLambdaVPCAccessExecutionRole` is the one acceptable AWS-managed policy

**Context.** Project rule (CLAUDE.md): no wildcard IAM. Lambda functions
running in a VPC need to manage their own ENIs (`ec2:CreateNetworkInterface`,
`DeleteNetworkInterface`, `DescribeNetworkInterfaces`, plus ENI assignment
permissions). Reproducing that policy verbatim adds maintenance with no
security upside; AWS already publishes it as a managed policy that they keep
in sync with new ENI features.

**Decision.** Attach the AWS-managed
`arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole` to
the Lambda execution role. All other permissions (Bedrock, Secrets Manager,
DynamoDB, SSM, RDS describe) are inline and scoped to specific resource
ARNs and specific actions.

**Alternatives considered.**
- Inline copy of the managed policy: drift over time as AWS adds new
  ENI-related actions; we'd lag and our Lambda would silently fail on
  the next ENI feature.
- Drop VPC entirely (use RDS Data API instead of psycopg-in-VPC): kills
  the "real production posture" goal in CLAUDE.md, and the Data API has
  hard latency floors that make the demo workload less impressive.

**Consequences.** Single deviation from "no managed policies". Documented
here so the deviation is intentional and reviewable.

**v1.5 migration path.** None expected. AWS-managed VPC ENI policy remains
the right tool for this job.

---

## ADR-005 — Gateway VPC endpoints in v1, interface endpoints in v1.5

**Context.** A Lambda inside private subnets has two ways to reach AWS APIs:
(1) NAT egress to the public AWS endpoint, or (2) a VPC endpoint that pins
the call to the AWS network. Endpoints come in two flavors:

- **Gateway** (S3, DynamoDB): free, route-table-attached, no SG management.
- **Interface** (SSM, Secrets Manager, Bedrock Runtime): an ENI per subnet
  per service (~$7.20/mo each) plus $0.01/GB processed, plus a security
  group to manage.

For a one-day demo with a NAT gateway already in the picture, the math on
the three interface endpoints we'd want (SSM + Secrets Manager + Bedrock
Runtime, ~$22/mo + $0.01/GB) does not justify itself versus letting those
calls take the NAT egress path for the demo's lifetime.

**Decision.**
- v1: Provision **gateway endpoints only** (S3, DynamoDB). They are free,
  remove DynamoDB and S3 traffic from NAT data charges, and add no
  ongoing operational burden.
- v1: SSM, Secrets Manager, and Bedrock Runtime calls flow through the NAT
  gateway. This is fine for a workload that calls these handfuls of times
  per request, not millions.
- v1.5: Add interface endpoints when the platform runs continuously and
  NAT data charges + cross-AZ data charges start to dominate the bill.

**Alternatives considered.**
- All endpoints (gateway + interface) from day one: ~$22/mo plus
  per-AZ ENI costs that double or triple if we add HA NAT later. For a
  demo running ~24h, that's a real waste.
- No endpoints, all NAT egress: simpler still but pays NAT data charges
  on every DynamoDB metric write. With our per-second metric pattern
  that adds up faster than the $0 gateway endpoints.

**Consequences.** Lambda cold start hits NAT for SSM + Secrets Manager
parameter fetches and for Bedrock Converse calls. Acceptable for v1; a
real platform with steady-state traffic should add the interface endpoints
to keep traffic on AWS's private network and to remove NAT as a single
point of failure for AWS API calls.

**v1.5 migration path.**
1. Create a security group `vpc-endpoints` allowing 443 ingress from the
   Lambda SG only.
2. Add `aws_vpc_endpoint` resources for `ssm`, `secretsmanager`,
   `bedrock-runtime`, attached to the private subnets and the SG.
3. Set `private_dns_enabled = true` so existing SDK calls automatically
   resolve to the endpoint.

---

## ADR-006 — Action-only IAM wildcards for `rds:DescribeDBClusters` and X-Ray

**Context.** The "no wildcard IAM" rule (CLAUDE.md) requires every action to
target a specific resource ARN. Two actions used by this Lambda do not
support resource-level permissions in IAM:

1. `rds:DescribeDBClusters` — used to sample `ServerlessV2ScalingConfiguration`
   each second for the per-second ACU metric. AWS's IAM service-authorization
   reference lists this action as supporting only `Resource: "*"`.

2. `xray:PutTraceSegments` and `xray:PutTelemetryRecords` — required when
   `tracing_config.mode = "Active"` so the Lambda runtime can emit
   trace data. Both list `Resource: "*"` only.

3. `cloudwatch:GetMetricData` — only way to read real-time
   `ServerlessDatabaseCapacity` (the per-second ACU value the workload
   executor samples). CloudWatch metric reads do not honor metric-level
   resource ARNs in IAM. Application code is constrained to only query
   our cluster's namespace+dimensions.

**Decision.** Allow these specific actions with `Resource: "*"`. Do not
expand the wildcard to other actions. Rely on application code to scope
calls to the cluster we own (we pass `DBClusterIdentifier` explicitly).

**Alternatives considered.**
- Skip the per-second ACU sample: kills the demo's "watch it scale"
  story (already partly degraded by CloudWatch's 1-minute granularity
  per ADR-008/009).
- Replace `rds:DescribeDBClusters` with a Postgres SQL query for
  capacity info: Aurora exposes some capacity-adjacent state via
  custom GUCs, but no documented authoritative ACU value. Unstable.
- Skip X-Ray tracing: would silence one observability dimension that's
  cheap and useful when something is slow. Not worth the savings.

**Consequences.** The execution role technically allows describing every
cluster in the account. In a single-account v1 demo this is moot. In a
multi-tenant production account the impact is "any caller of this Lambda
could leak metadata about unrelated clusters", mitigated by the fact that
the application code never returns describe output to the caller.

**v1.5 migration path.** None expected from AWS. Watch the IAM
service-authorization reference for `rds:DescribeDBClusters` to gain
resource-level support; tighten if it ever does.

---

## ADR-007 — AWS-managed Aurora master credentials

**Context.** The Aurora module was first written with a Terraform-owned
password flow:

```hcl
resource "random_password" "master"        { length = 32 }
resource "aws_secretsmanager_secret" "..." { name = "..." }
resource "aws_secretsmanager_secret_version" "..." {
  secret_string = jsonencode({ ..., password = random_password.master.result })
}
resource "aws_rds_cluster" "this" {
  master_password = random_password.master.result
}
```

That puts the master password into Terraform state in plaintext. State is
local in v1 (ADR-002) and migrates to S3 in v1.5. The password should never
have entered state in the first place — letting it migrate to S3, even with
encryption at rest, expands the attack surface unnecessarily.

**Decision.** Use AWS-managed master credentials via the cluster's
`manage_master_user_password = true` argument. RDS generates the password,
stores it in a Secrets Manager secret tied to the cluster, and rotates it
on its own schedule. Terraform never holds the password. The cluster
exposes the managed secret's ARN via the read-only attribute
`master_user_secret[0].secret_arn`, which the module re-exports as
`master_user_secret_arn`.

The Lambda's IAM policy continues to scope `secretsmanager:GetSecretValue`
to that single ARN. Application code reads username and password from the
secret at cold start and combines them with the cluster endpoint (env var)
to form a connection string.

**Alternatives considered.**
- Mark `random_password.master.result` and the `secret_string` as
  `sensitive`: hides the value from `terraform plan`/`apply` output, but
  leaves it stored in plaintext inside the state file. Cosmetic, not
  protective.
- Encrypt state with a customer-managed KMS key (Terraform v1.10+ remote
  state encryption): worth doing in v1.5 alongside the S3 backend
  migration; doesn't help v1's local-state setup.
- IAM auth for Postgres (no password at all): the right end-state. Out
  of scope for v1 — requires per-team DB users and a token-refresh
  loop. Slated for v1.5.

**Consequences.**
- Password is never in Terraform state. Safe to migrate state to S3.
- AWS controls the rotation schedule. Operator does not configure it.
- The managed secret name is autogenerated (`rds!cluster-<uuid>-<rand>`),
  not human-friendly. Trade-off accepted for the security improvement.

**Two-phase apply was required to land this without recreating the
cluster.** A naive single-config-change attempts to evaluate
`aws_rds_cluster.this.master_user_secret[0]` against current state where
the list is still empty, and Terraform errors with "the collection has no
elements." The migration:

1. Phase 1 — set `manage_master_user_password = true` and remove
   `master_password` from the cluster argument, while keeping the legacy
   `random_password`, `aws_secretsmanager_secret`, and
   `aws_secretsmanager_secret_version` resources. The module output keeps
   resolving from the legacy secret. Apply: cluster modified in-place
   (no replacement); AWS creates the managed secret; state populates
   `master_user_secret[0]`.

2. Phase 2 — drop the three legacy resources, flip the module output to
   `aws_rds_cluster.this.master_user_secret[0].secret_arn`, drop the
   `random` provider pin from this module and the env. Apply: legacy
   secret destroyed (with 7-day recovery window), `random_password`
   removed from state, IAM policy updates from the legacy ARN to the
   managed ARN, Lambda env var updates, Lambda is redeployed, `/health`
   still returns 200 OK.

**v1.5 migration path.** None — the AWS-managed pattern is what the v1.5
state-on-S3 migration relies on.

---

## ADR-008 — WorkloadSpec semantics, ACU honesty, table allowlist

**Context.** The `WorkloadSpec` schema has fields that look independent
but interact in ways the model and the executor must agree on. Three
choices made up front:

1. **`duration_seconds` is a hard cap; `row_count` is a target.** The
   schema bounds row_count at 1..100,000 and duration_seconds at 5..60.
   "Insert 100,000 rows in 5 seconds" implies 20k inserts/sec which a
   single Lambda over psycopg cannot sustain. If the executor honored
   row_count as a hard count, the user would either get a timeout error
   or wait far longer than they asked for. Honoring duration as the cap
   gives a predictable user experience: you ask for X seconds, you get X
   seconds, and the platform reports how many rows actually landed.

   The intent-parser system prompt makes this explicit and clips
   unrealistic row_count values to a plausible target. The executor
   loop in workload.py exits on whichever comes first: target rows
   reached, or duration elapsed.

2. **`RunRecord` carries `rows_completed` separately from `row_count`.**
   The user can see the gap between ask and reality. The summary
   prompt is required to surface that gap when it's material.

3. **`starting_acu` and `peak_acu` are passed to the summary prompt; the
   summary must narrate ACU behavior honestly.** Aurora Serverless v2
   doesn't always scale within a 60-second window — small workloads or
   read-heavy ones may stay at 0.5 ACU. The headline of the demo is "see
   the cluster autoscale," and a summary that fakes a scaling story
   when none happened would undermine the entire platform. The system
   prompt requires the words "did not scale" or "stayed at X" when
   `peak_acu == starting_acu`.

**Decision.** Schema as defined in `app/src/ngx_workload_lab/models.py`:
`workload_type`, `row_count` (target), `mix_ratio`, `duration_seconds`
(hard cap), `table_name` (allowlisted to `{"workload_orders"}`).
RunRecord includes `rows_completed`, `starting_acu`, `peak_acu`. Summary
prompt enforces ACU honesty.

**Alternatives considered.**
- `row_count` as the hard cap: matches user mental model ("insert 50k
  rows") but makes "insert 100k rows in 5 seconds" a contract that
  Aurora cannot fulfill from a single Lambda. Either we accept timing
  out the Lambda, or we silently exceed the duration. Both are worse
  than honest under-delivery.
- Drop `row_count` from the spec entirely: the executor pushes as hard
  as it can for the duration. Loses user intent ("I want roughly N
  rows of work").
- Let Bedrock pick any `table_name`: violates "Bedrock never drives
  privileged actions" (CLAUDE.md). Even seeing a typo'd table name
  leak into a SQL string is too close to prompt-injection-as-code.

**Table-name allowlist.** Bedrock chooses workload type and row counts
but not table identifiers. The intent-parser prompt instructs the model
to always emit `"workload_orders"` regardless of what the user typed,
and the Pydantic validator rejects anything else with a 400. This
enforces "Bedrock never drives privileged actions" (CLAUDE.md): the
model cannot influence which table the executor writes to.

**Consequences.**
- Demo behavior is predictable (you get the seconds you asked for) at
  the cost of pretending the row_count number is exact.
- Summaries can read as deflating ("did not scale; capacity stayed at
  0.5 throughout") — this is intentional and honest.
- Adding new tables requires editing `ALLOWED_TABLE_NAMES` AND adding
  the schema/seed migration in workload.py. Not free, by design.

**v1.5 migration path.** Larger workloads → async via Step Functions or
SQS, removing the 60-second duration cap. The schema would gain
`duration_seconds: 5..3600` once the synchronous-Lambda constraint is
gone.

---

## ADR-009 — `duration_seconds` capped at 5..20 in v1 (API GW timeout)

**Context.** ADR-008 framed `duration_seconds` as a hard cap. Initial
draft had it at 5..60 to match Lambda's 60-second timeout. That doesn't
fit the synchronous request path: API Gateway HTTP API integration
timeout maxes at **30 seconds**, regardless of Lambda's timeout. A
60-second workload returns 504 from API GW long before Lambda finishes.

The full request budget breaks down roughly:
  - Lambda cold start (VPC ENI on Hyperplane): 2–4s
  - Bedrock Converse (intent parser):           1–3s
  - Postgres connect + ensure table:            1–2s
  - **Workload run** (the budget we control):   ?
  - Bedrock Converse (run summary):             1–3s
  - DynamoDB writes:                            <1s
  - Response serialization:                     <1s

That leaves ~15–20 seconds for the workload itself within a 30-second
API GW ceiling.

**Decision.** Tighten `WorkloadSpec.duration_seconds` to **5..20** in
v1. Update the intent parser system prompt to enforce this (Bedrock
clips "give me 60 seconds" to 20 with the same honesty pattern as
ADR-008). Set `REQUEST_DEADLINE_SECONDS = 28.0` in `main.py` as the
asyncio.wait_for budget, leaving 2 seconds of buffer before API GW
returns 504.

**Alternatives considered.**
- Keep schema at 5..60, runtime-clamp to 20 in the executor: confusing
  output ("you asked for 60s, got 20s") that the schema and prompt
  don't acknowledge. Schema and behavior should agree.
- Switch from API Gateway HTTP API to REST API: REST API integration
  timeout maxes at 29 seconds — same constraint, no win. Adds the
  complexity of a different API tier with no benefit at this scope.
- Async kickoff (POST returns 202 + run_id, executor runs out-of-band):
  the right answer. Out of scope for v1 (Step Functions or SQS, plus a
  poller-style UI). Slated for v1.5.

**Consequences.**
- Aurora Serverless v2 publishes `ServerlessDatabaseCapacity` to
  CloudWatch at 1-minute granularity. Within a 20-second window we
  rarely see ACU change at all. The summary prompt narrates this
  honestly per ADR-008.
- The demo headline ("watch the cluster scale") is accurate over
  multiple runs but will often show "did not scale" in any single run.
  This is a real platform limitation worth surfacing rather than hiding.

**v1.5 migration path.** Async execution via Step Functions or SQS:
  1. POST /workloads validates intent and returns `202 + run_id`
     immediately.
  2. A Step Functions state machine drives the workload, writes
     metrics, and runs the summary. Duration cap rises to whatever
     the orchestration tier allows (Step Functions: 1 year max).
  3. The schema bound on `duration_seconds` rises to 5..3600.
  4. The UI polls `GET /workloads/{run_id}` for incremental progress
     instead of waiting on a synchronous response.

---

## ADR-010 — CI uses static AWS keys in v1; OIDC role is the v1.5 path

**Context.** The CI workflows (`.github/workflows/ci.yml`,
`.github/workflows/deploy-dev.yml`) need AWS credentials to run
`terraform plan` on PRs and `terraform apply` on merges to main.
Two common patterns:

1. **Static IAM user access keys** stored in GitHub Secrets, passed in
   via env vars on each workflow run.
2. **GitHub OIDC** with a per-repo IAM role that GitHub assumes via STS
   for the duration of the job — no long-lived credentials anywhere.

OIDC is the right answer for any environment that lives beyond a one-day
demo. Setting it up requires creating an IAM OIDC provider for
`token.actions.githubusercontent.com`, an IAM role with a trust policy
that scopes to `repo:owner/repo:ref:refs/heads/main` (and equivalent for
PRs), and a Terraform module to manage that role's policy. About 30
minutes of yak-shaving.

**Decision.** v1 uses GitHub Secrets `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` with permissions equivalent to what
`terraform apply` needs (a wide policy in the demo account; would be
narrowly-scoped in a real account). The deploy workflow runs against
a GitHub Environment named `dev-apply` with required reviewers — so
even with static keys, an apply needs human approval.

**Alternatives considered.**
- OIDC from day one: the right end-state, see above. Skipped to keep
  the CI step in scope.
- Run Terraform manually only, no CI deploy at all: loses the
  plan-on-PR review surface that catches half-baked module changes
  before they merge.

**Consequences.** A leaked GitHub repo secret could give an attacker
the same powers Terraform has. The keys live only in GitHub Secrets
(rotated by hand if needed) — not in commits, not in env files.

**v1.5 migration path.**
1. Create IAM OIDC provider for `token.actions.githubusercontent.com`
   (Terraform-managed, in a new `infra/modules/github_oidc/`).
2. Create per-environment IAM role with trust policy scoped to the
   repo + branch + workflow-job pair.
3. Replace `aws-actions/configure-aws-credentials` with the OIDC
   variant: `role-to-assume:` + `aws-region:`.
4. Delete the GitHub repo secrets.
5. Rotate the static keys out of the AWS account (deactivate, then
   delete after a cool-off).

---

## ADR-012 — Async self-invoke for workload execution

**Context.** ADR-008/009 capped `duration_seconds` at 5..20 because the
synchronous request path was bounded by API Gateway HTTP API's 30-second
integration timeout. That cap meant single-run workloads could not run
long enough for Aurora Serverless v2 to scale visibly within a request
(CloudWatch publishes `ServerlessDatabaseCapacity` at 1-minute
granularity, so any single sub-30-second window almost always shows
zero ACU change).

The "watch the cluster scale" headline of the demo therefore couldn't
fire in v1 sync. Live demos showed the cluster scaling *between* runs
(0.5 → 2.0 → 3.0 over a sequence) but never *within* one.

**Decision.** Move workload execution to an async, self-invoked Lambda
path:

1. `POST /workloads` parses intent synchronously (so a bad prompt still
   returns 400 immediately), persists a `running` `RunRecord` with the
   parsed `WorkloadSpec`, then calls `lambda.invoke(InvocationType="Event")`
   on its own function with a sentinel payload (`_ngx_async_workload`).
   It returns 202 + `run_id` within a few seconds.
2. The async self-invocation lands on the same Lambda function. The
   top-level `handler()` checks the event for the sentinel key and
   dispatches to the worker path (executor → metrics → Bedrock summary)
   instead of forwarding to Mangum/FastAPI.
3. The UI polls `GET /workloads/{run_id}` every 2 seconds until status
   reaches a terminal value (`complete` / `bedrock_error` /
   `workload_error` / `timeout`), then renders the chart and summary.

`WorkloadSpec.duration_seconds` rises to **5..180**. Lambda timeout
rises to **600 seconds** (10 min) — well over the 180s schema cap plus
Bedrock + DDB overhead, with margin for cold-start and connection
churn. The IAM execution role gains `lambda:InvokeFunction` on the
function's own ARN (constructed from the known function name to avoid
a Terraform graph cycle on `aws_lambda_function.this.arn`).

**Alternatives considered.**
- **Step Functions Standard.** The textbook async-orchestration tier.
  Adds a state-machine resource, IAM trust between SFN and Lambda, and
  a separate state-tracking primitive that effectively duplicates the
  RunRecord. The benefit (richer retries, history) doesn't earn its
  complexity at this scope. SFN is the v1.5+ path if the worker tier
  ever needs branching, retries, or human approval.
- **Amazon SQS + a separate worker Lambda.** Buy nothing over async
  self-invoke for a single-step workload, and pays for a queue that
  carries one message per run.
- **Two distinct Lambda functions** (HTTP API in front, worker
  separately). Cleaner boundary but doubles cold-start surface, doubles
  the Terraform-managed function count, and forces the env vars to
  exist twice.
- **Keep sync, switch from API Gateway to ALB.** ALB target-group
  timeout is 4000s — generous enough for any plausible workload. But
  ALB-as-front-door costs ~$16/mo at idle and pulls our edge story
  away from the CloudFront + HTTP API combo we already deployed.

Self-invoke wins on simplicity at scope: same code, same image, same
function, same env vars, one new IAM action.

**Consequences.**
- Workloads can now run up to 180 seconds, and Lambda has 600s of
  timeout headroom. Aurora Serverless v2 will visibly scale within a
  single 60-180s run when CPU pressure crosses the scaling threshold.
- The UI shows a "running" state with elapsed seconds and sample
  count while polling — a slight UX regression from "type prompt, get
  chart in 12 seconds" but a correct one.
- Every run now incurs two Lambda invocations (the HTTP one + the
  async one). Cold-start cost is paid by the HTTP one; the async one
  reuses the warm execution context most of the time. Negligible cost
  impact at demo volume.
- Async invocations have their own retry semantics. Lambda retries
  failed async invocations twice by default. The worker writes a
  `workload_error` `RunRecord` on failure, so the UI sees the failure
  rather than hanging on `running` forever — but a flaky invocation
  could write the failure twice. Acceptable for v1; v1.5 should set
  `MaximumRetryAttempts: 0` on the function's async config to disable
  retries entirely (the workload itself isn't idempotent — re-running
  it doubles inserts).

**v1.5 migration path.** None required for the headline scaling demo.
The natural next step (when workloads need to span 15+ minutes, or
need branching/retries) is Step Functions. The async self-invoke path
maps cleanly onto a single-state SFN state machine, so the migration
is mechanical when the time comes.
