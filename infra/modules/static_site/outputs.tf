output "bucket_name" {
  description = "S3 bucket name (used by deploy script for aws s3 sync)."
  value       = aws_s3_bucket.site.id
}

output "bucket_arn" {
  description = "S3 bucket ARN."
  value       = aws_s3_bucket.site.arn
}

output "distribution_id" {
  description = "CloudFront distribution ID (used for cache invalidation)."
  value       = aws_cloudfront_distribution.site.id
}

output "distribution_domain" {
  description = "CloudFront distribution domain (e.g. d1234.cloudfront.net)."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "distribution_url" {
  description = "Full https URL for the UI."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}
