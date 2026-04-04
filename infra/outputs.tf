# --- Environment Status ---
output "env_active" {
  description = "Whether the environment is currently active"
  value       = var.env_active
}

# --- URLs ---
output "app_url" {
  description = "Application URL"
  value       = "https://${var.custom_domain}"
}

output "api_url" {
  description = "Backend API URL"
  value       = "https://${var.custom_domain}/api"
}

output "keycloak_url" {
  description = "Keycloak URL"
  value       = "https://${var.custom_domain}/auth"
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation)"
  value       = aws_cloudfront_distribution.main.id
}

# --- Compute (when active) ---
output "backend_instance_id" {
  description = "Backend EC2 instance ID — use for SSM session"
  value       = var.env_active ? aws_instance.backend[0].id : "inactive"
}

output "keycloak_instance_id" {
  description = "Keycloak EC2 instance ID — use for SSM session"
  value       = var.env_active ? aws_instance.keycloak[0].id : "inactive"
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = var.env_active ? aws_db_instance.main[0].endpoint : "inactive"
}

output "prometheus_instance_id" {
  description = "Prometheus EC2 instance ID — use for SSM session"
  value       = var.env_active ? aws_instance.prometheus[0].id : "inactive"
}


# --- S3 Buckets ---
output "frontend_bucket" {
  description = "S3 bucket for frontend assets"
  value       = aws_s3_bucket.frontend.id
}

output "artifacts_bucket" {
  description = "S3 bucket for build artifacts (JARs)"
  value       = aws_s3_bucket.artifacts.id
}

# --- CI/CD ---
output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC — set as AWS_CICD_ROLE_ARN secret"
  value       = aws_iam_role.github_actions.arn
}

# --- Networking ---
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "alb_dns" {
  description = "Internal ALB DNS"
  value       = var.env_active ? aws_lb.main[0].dns_name : "inactive"
}
