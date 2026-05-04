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

**Decision.** Allow these specific actions with `Resource: "*"`. Do not
expand the wildcard to other actions. Rely on application code to scope
calls to the cluster we own (we pass `DBClusterIdentifier` explicitly).

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
