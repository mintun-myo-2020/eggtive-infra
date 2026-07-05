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
output "app_deploy_role_arns" {
  description = "IAM role ARNs for each app's GitHub Actions deploy — set as AWS_CICD_ROLE_ARN in each app repo"
  value       = { for k, v in aws_iam_role.app_deploy : k => v.arn }
}

output "infra_cicd_role_arn" {
  description = "IAM role ARN for infra repo's Terraform CI/CD"
  value       = aws_iam_role.infra_cicd.arn
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

# --- Generic App Workloads ---
output "app_workload_instance_ids" {
  description = "Instance IDs for generic app workloads — use for SSM session"
  value       = { for k, v in aws_instance.app_workload : k => v.id }
}

# --- Container Workloads (ECS) ---
output "ecr_repo_urls" {
  description = "ECR repository URLs for each container app"
  value       = { for k, v in aws_ecr_repository.app : k => v.repository_url }
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = length(aws_ecs_cluster.main) > 0 ? aws_ecs_cluster.main[0].name : "none"
}
