# Local state for v1.
# v1.5 migrates to S3 backend + DynamoDB lock table + GitHub OIDC role; see DECISIONS.md.
terraform {
  backend "local" {}
}
