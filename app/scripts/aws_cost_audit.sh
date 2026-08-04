#!/usr/bin/env bash
# Answer two questions about this deployment's AWS spend:
#
#   1. Which services are actually costing money?
#   2. Has anyone been driving traffic at the (unauthenticated) API?
#
# The v1 stack bills on two axes that are easy to confuse:
#
#   - Idle floor. Aurora Serverless v2 is pinned at min_capacity = 0.5 ACU
#     (it never scales to zero) and a NAT Gateway runs continuously so the
#     in-VPC Lambda can reach Bedrock/SSM/Secrets Manager. Both bill 24/7
#     with zero traffic.
#   - Per-request. Bedrock Converse (two calls per run), Lambda duration,
#     Aurora ACUs above the floor, DynamoDB on-demand writes.
#
# Section 1 separates them. Sections 2-4 attribute per-request spend to
# callers, so "is someone hammering the open API" gets a real answer rather
# than a guess.
#
# Everything is discovered from Terraform outputs or from the resource-name
# prefix — no ARNs are hardcoded (CLAUDE.md).
#
# Usage:
#   bash app/scripts/aws_cost_audit.sh [env] [days]
#
#   env   environment name, default "dev"
#   days  lookback window, default 30
#
# Requires: awscli v2, credentials with read access to Cost Explorer,
# CloudWatch Logs, CloudWatch, DynamoDB, and CloudTrail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"

ENVIRONMENT="${1:-dev}"
LOOKBACK_DAYS="${2:-30}"
ENV_DIR="$REPO_ROOT/infra/envs/$ENVIRONMENT"

AWS_BIN="${AWS_BIN:-aws}"
TF_BIN="${TF_BIN:-terraform}"

PROJECT="${PROJECT:-ai-workload-lab}"
NAME_PREFIX="$PROJECT-$ENVIRONMENT"
REGION="${AWS_REGION:-us-east-2}"

# Cost Explorer is a global service fronted in us-east-1 regardless of where
# the workload runs.
CE_REGION="us-east-1"

if ! command -v "$AWS_BIN" >/dev/null; then
  echo "ERROR: '$AWS_BIN' not found. Set AWS_BIN to the absolute path if not on PATH." >&2
  exit 1
fi

############################
# Portable UTC date helpers
############################

# GNU date (Linux) and BSD date (macOS) disagree on relative-date flags.
if date -u -d "@0" >/dev/null 2>&1; then
  _date_is_gnu=1
else
  _date_is_gnu=0
fi

days_ago() {
  # days_ago <n> <strftime-format>
  local days="$1" fmt="$2"
  if [ "$_date_is_gnu" -eq 1 ]; then
    date -u -d "${days} days ago" +"$fmt"
  else
    date -u -v-"${days}"d +"$fmt"
  fi
}

now_fmt() { date -u +"$1"; }

START_DATE="$(days_ago "$LOOKBACK_DAYS" '%Y-%m-%d')"
END_DATE="$(now_fmt '%Y-%m-%d')"
START_EPOCH="$(days_ago "$LOOKBACK_DAYS" '%s')"
END_EPOCH="$(now_fmt '%s')"
START_ISO="$(days_ago "$LOOKBACK_DAYS" '%Y-%m-%dT%H:%M:%SZ')"
END_ISO="$(now_fmt '%Y-%m-%dT%H:%M:%SZ')"

rule() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

############################
# Identity
############################

rule "Identity"
if ! "$AWS_BIN" sts get-caller-identity --output table 2>/dev/null; then
  echo "ERROR: AWS credentials are not valid in this shell." >&2
  echo "       Run 'aws sso login' (or export a working profile) and retry." >&2
  exit 1
fi
note "region=$REGION  window=$START_DATE..$END_DATE ($LOOKBACK_DAYS days)"

############################
# Resource discovery
############################

# Prefer Terraform outputs; fall back to prefix search so the script still
# works from a machine without state.
tf_output() {
  local key="$1"
  [ -d "$ENV_DIR" ] || return 1
  "$TF_BIN" -chdir="$ENV_DIR" output -raw "$key" 2>/dev/null || return 1
}

API_LOG_GROUP="/aws/apigw/${NAME_PREFIX}-api"
LAMBDA_LOG_GROUP="/aws/lambda/${NAME_PREFIX}-api"

RUNS_TABLE="$(tf_output dynamodb_table_name || true)"
if [ -z "${RUNS_TABLE:-}" ]; then
  RUNS_TABLE="$("$AWS_BIN" dynamodb list-tables --region "$REGION" \
    --query "TableNames[?starts_with(@, \`${NAME_PREFIX}\`)] | [0]" \
    --output text 2>/dev/null || true)"
fi
[ "${RUNS_TABLE:-None}" = "None" ] && RUNS_TABLE=""

rule "Discovered resources"
note "api access log group : $API_LOG_GROUP"
note "lambda log group     : $LAMBDA_LOG_GROUP"
note "runs table           : ${RUNS_TABLE:-<not found>}"

############################
# 1. Where the money went
############################

rule "1a. Cost by service (last $LOOKBACK_DAYS days, unblended USD)"
"$AWS_BIN" ce get-cost-and-usage \
  --region "$CE_REGION" \
  --time-period "Start=$START_DATE,End=$END_DATE" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount!=`0`].{Service:Keys[0],USD:Metrics.UnblendedCost.Amount}[]' \
  --output table || note "Cost Explorer call failed (needs ce:GetCostAndUsage; may be disabled on the account)."

rule "1b. Daily total (spot a step-change — a spike means traffic, a flat line means idle burn)"
"$AWS_BIN" ce get-cost-and-usage \
  --region "$CE_REGION" \
  --time-period "Start=$START_DATE,End=$END_DATE" \
  --granularity DAILY \
  --metrics UnblendedCost \
  --query 'ResultsByTime[].{Day:TimePeriod.Start,USD:Total.UnblendedCost.Amount}' \
  --output table || true

rule "1c. This project's tagged resources only (Project=$PROJECT)"
# Isolates the lab from anything else in the account. Requires the
# Project tag to be activated as a cost allocation tag in Billing.
"$AWS_BIN" ce get-cost-and-usage \
  --region "$CE_REGION" \
  --time-period "Start=$START_DATE,End=$END_DATE" \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --filter "{\"Tags\":{\"Key\":\"Project\",\"Values\":[\"$PROJECT\"]}}" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[].{Service:Keys[0],USD:Metrics.UnblendedCost.Amount}[]' \
  --output table \
  || note "No tagged data. Activate 'Project' as a cost allocation tag in Billing > Cost allocation tags (takes ~24h to backfill)."

############################
# CloudWatch Logs Insights helper
############################

run_insights() {
  # run_insights <log-group> <query-string> <label>
  local group="$1" query="$2" label="$3" qid status

  if ! "$AWS_BIN" logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "$group" \
    --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q .; then
    note "log group $group not found — skipping $label"
    return 0
  fi

  qid="$("$AWS_BIN" logs start-query --region "$REGION" \
    --log-group-name "$group" \
    --start-time "$START_EPOCH" --end-time "$END_EPOCH" \
    --query-string "$query" \
    --output text --query 'queryId' 2>/dev/null || true)"

  if [ -z "$qid" ]; then
    note "could not start query for $label"
    return 0
  fi

  for _ in $(seq 1 60); do
    status="$("$AWS_BIN" logs get-query-results --region "$REGION" \
      --query-id "$qid" --output text --query 'status' 2>/dev/null || echo Failed)"
    case "$status" in
      Complete) break ;;
      Failed | Cancelled | Timeout)
        note "query $label ended: $status"
        return 0
        ;;
      *) sleep 2 ;;
    esac
  done

  "$AWS_BIN" logs get-query-results --region "$REGION" \
    --query-id "$qid" \
    --query 'results[].[field,value]' --output text 2>/dev/null \
    || note "no results for $label"
}

############################
# 2. Who called the API
############################

rule "2a. Top caller IPs against the API (source: API GW access logs)"
note "Any IP here that is not yours called the public execute-api URL directly."
run_insights "$API_LOG_GROUP" \
  'fields ip, userAgent | stats count() as hits by ip, userAgent | sort hits desc | limit 40' \
  "top caller IPs"

rule "2b. Request volume by day and route"
run_insights "$API_LOG_GROUP" \
  'fields @timestamp, routeKey, httpMethod, status | stats count() as hits by bin(1d) as day, httpMethod, status | sort day desc | limit 60' \
  "daily request volume"

rule "2c. Workload kick-offs only (POST /workloads — these are what cost Bedrock + Aurora)"
note "GET polls are cheap; each POST is a full run: 2 Bedrock calls + an Aurora workload."
run_insights "$API_LOG_GROUP" \
  'fields ip, httpMethod, routeKey | filter httpMethod = "POST" | stats count() as runs by ip | sort runs desc | limit 40' \
  "POST /workloads by IP"

############################
# 3. Bedrock token burn
############################

rule "3. Bedrock token usage (from the log metric filters in the observability module)"
for metric in BedrockInputTokens BedrockOutputTokens; do
  printf '\n  -- %s --\n' "$metric"
  "$AWS_BIN" cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace "ngx-workload-lab" \
    --metric-name "$metric" \
    --start-time "$START_ISO" --end-time "$END_ISO" \
    --period 86400 --statistics Sum \
    --query 'sort_by(Datapoints,&Timestamp)[].{Day:Timestamp,Tokens:Sum}' \
    --output table || note "no datapoints for $metric"
done

rule "3b. Bedrock InvokeModel/Converse calls seen by CloudTrail (who invoked, from where)"
note "CloudTrail retains 90 days of management events by default."
"$AWS_BIN" cloudtrail lookup-events \
  --region "$REGION" \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=bedrock.amazonaws.com \
  --start-time "$START_ISO" --end-time "$END_ISO" \
  --max-results 25 \
  --query 'Events[].{Time:EventTime,Name:EventName,User:Username,Source:CloudTrailEvent}' \
  --output json 2>/dev/null | head -60 \
  || note "no Bedrock events in CloudTrail (data-plane Converse calls may not be logged as management events)."

############################
# 4. Runs actually executed
############################

if [ -n "$RUNS_TABLE" ]; then
  rule "4a. Total workload runs ever recorded"
  # Header rows are the ones with metric_ts = "run"; everything else is a
  # per-second metric sample (storage.py HEADER_SK).
  "$AWS_BIN" dynamodb scan \
    --region "$REGION" \
    --table-name "$RUNS_TABLE" \
    --filter-expression "metric_ts = :h" \
    --expression-attribute-values '{":h":{"S":"run"}}' \
    --select COUNT \
    --query '{Runs:Count,Scanned:ScannedCount}' \
    --output table || note "scan failed"

  rule "4b. Most recent runs (GSI status-created_at, sparse — header rows only)"
  for st in complete running bedrock_error workload_error pending; do
    cnt="$("$AWS_BIN" dynamodb query \
      --region "$REGION" \
      --table-name "$RUNS_TABLE" \
      --index-name "status-created_at" \
      --key-condition-expression "#s = :s" \
      --expression-attribute-names '{"#s":"status"}' \
      --expression-attribute-values "{\":s\":{\"S\":\"$st\"}}" \
      --select COUNT --query 'Count' --output text 2>/dev/null || echo '?')"
    printf '  %-16s %s\n' "$st" "$cnt"
  done

  rule "4c. Newest 10 completed runs with their prompts"
  note "Reading the prompts tells you whether the traffic is yours or a stranger's."
  "$AWS_BIN" dynamodb query \
    --region "$REGION" \
    --table-name "$RUNS_TABLE" \
    --index-name "status-created_at" \
    --key-condition-expression "#s = :s" \
    --expression-attribute-names '{"#s":"status"}' \
    --expression-attribute-values '{":s":{"S":"complete"}}' \
    --no-scan-index-forward --max-items 10 \
    --query 'Items[].{Created:created_at.S,Prompt:spec.M.original_prompt.S,InTok:bedrock_input_tokens.N,OutTok:bedrock_output_tokens.N}' \
    --output table 2>/dev/null || note "query failed"
else
  rule "4. Runs table not found — skipping run-count section"
fi

############################
# 5. The idle floor
############################

rule "5. Always-on resources (these bill with zero traffic)"

printf '\n  -- NAT gateways --\n'
"$AWS_BIN" ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[].{Id:NatGatewayId,Created:CreateTime,VPC:VpcId}' \
  --output table 2>/dev/null || note "none / no access"

printf '\n  -- Aurora Serverless v2 scaling floor --\n'
"$AWS_BIN" rds describe-db-clusters --region "$REGION" \
  --query "DBClusters[?starts_with(DBClusterIdentifier, \`${NAME_PREFIX}\`)].{Cluster:DBClusterIdentifier,Status:Status,MinACU:ServerlessV2ScalingConfiguration.MinCapacity,MaxACU:ServerlessV2ScalingConfiguration.MaxCapacity,AutoPauseSecs:ServerlessV2ScalingConfiguration.SecondsUntilAutoPause}" \
  --output table 2>/dev/null || note "none / no access"

printf '\n  -- Actual ACU consumption (daily avg vs peak) --\n'
CLUSTER_ID="$("$AWS_BIN" rds describe-db-clusters --region "$REGION" \
  --query "DBClusters[?starts_with(DBClusterIdentifier, \`${NAME_PREFIX}\`)].DBClusterIdentifier | [0]" \
  --output text 2>/dev/null || true)"
if [ -n "${CLUSTER_ID:-}" ] && [ "$CLUSTER_ID" != "None" ]; then
  note "cluster: $CLUSTER_ID — if Average tracks MinACU and Maximum never rises, nobody is using it"
  "$AWS_BIN" cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace AWS/RDS \
    --metric-name ServerlessDatabaseCapacity \
    --dimensions "Name=DBClusterIdentifier,Value=$CLUSTER_ID" \
    --start-time "$START_ISO" --end-time "$END_ISO" \
    --period 86400 --statistics Average Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[].{Day:Timestamp,AvgACU:Average,PeakACU:Maximum}' \
    --output table || note "no ACU datapoints"
fi

rule "Done"
cat <<'EOF'
  How to read this:

  - Section 1 flat across days + section 5 AvgACU pinned at the minimum
    + section 4 showing few runs  ->  idle infrastructure, not visitors.
    Fixes: destroy between demos, set Aurora min_capacity = 0 with
    auto-pause, or swap the NAT Gateway for VPC interface endpoints
    (the ADR-005 v1.5 item).

  - Section 2 showing unfamiliar IPs with POST hits, or section 3 token
    counts far above what your own demos would produce  ->  the open API
    is being used by someone else. The $default route is
    authorization_type = "NONE" and the execute-api URL is public; CORS
    only constrains browsers, not curl.
    Fixes: a Lambda authorizer or API key, AWS WAF with a rate rule in
    front of CloudFront, and tighter stage throttling.

  Note: CloudFront has no access logging configured, so plain page views
  of the UI are not recorded anywhere. Only API calls appear above.
EOF
