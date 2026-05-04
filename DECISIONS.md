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
