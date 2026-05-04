#!/usr/bin/env bash
# Deploy the static UI to S3 and invalidate the CloudFront edge cache.
#
# Inputs come from Terraform outputs in infra/envs/dev:
#   ui_bucket_name      — S3 bucket
#   ui_distribution_id  — CloudFront distribution ID
#   api_endpoint        — HTTP API base URL (substituted into config.js)
#
# Usage: bash app/scripts/deploy_ui.sh [env]   # env defaults to "dev"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$APP_DIR")"
UI_DIR="$APP_DIR/ui"
ENVIRONMENT="${1:-dev}"
ENV_DIR="$REPO_ROOT/infra/envs/$ENVIRONMENT"

AWS_BIN="${AWS_BIN:-aws}"
TF_BIN="${TF_BIN:-terraform}"

if ! command -v "$AWS_BIN" >/dev/null; then
  echo "ERROR: '$AWS_BIN' not found. Set AWS_BIN to the absolute path if not on PATH." >&2
  exit 1
fi
if ! command -v "$TF_BIN" >/dev/null; then
  echo "ERROR: '$TF_BIN' not found. Set TF_BIN to the absolute path if not on PATH." >&2
  exit 1
fi

echo "==> reading Terraform outputs from $ENV_DIR"
BUCKET=$("$TF_BIN" -chdir="$ENV_DIR" output -raw ui_bucket_name)
DISTRIBUTION_ID=$("$TF_BIN" -chdir="$ENV_DIR" output -raw ui_distribution_id)
API_URL=$("$TF_BIN" -chdir="$ENV_DIR" output -raw api_endpoint)

if [ -z "$BUCKET" ] || [ -z "$DISTRIBUTION_ID" ] || [ -z "$API_URL" ]; then
  echo "ERROR: missing Terraform outputs (bucket=$BUCKET, dist=$DISTRIBUTION_ID, api=$API_URL)" >&2
  exit 1
fi

STAGING="$APP_DIR/build/ui"
echo "==> staging UI in $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$UI_DIR/index.html" "$STAGING/"
cp "$UI_DIR/styles.css" "$STAGING/"
cp "$UI_DIR/index.js" "$STAGING/"
sed "s|__API_URL__|$API_URL|g" "$UI_DIR/config.template.js" > "$STAGING/config.js"

echo "==> uploading to s3://$BUCKET/"
"$AWS_BIN" s3 sync "$STAGING/" "s3://$BUCKET/" \
  --delete \
  --cache-control "public, max-age=300" \
  --no-progress

# index.html should not be cached aggressively at the browser, since it
# pins the whole asset graph. CloudFront still caches per the cache policy.
"$AWS_BIN" s3 cp "$STAGING/index.html" "s3://$BUCKET/index.html" \
  --cache-control "no-cache, must-revalidate" \
  --content-type "text/html; charset=utf-8" \
  --no-progress

echo "==> invalidating CloudFront $DISTRIBUTION_ID"
"$AWS_BIN" cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.{Id:Id,Status:Status}' \
  --output json

echo
echo "==> done"
UI_URL=$("$TF_BIN" -chdir="$ENV_DIR" output -raw ui_url 2>/dev/null || true)
echo "    UI:  $UI_URL"
echo "    API: $API_URL"
