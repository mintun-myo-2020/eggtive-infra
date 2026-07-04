variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "eggtive-spm"
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
  default     = "dev"
}

variable "env_active" {
  description = "Whether expensive resources (EC2, RDS, ALB, VPC endpoints) are active"
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "backend_instance_type" {
  description = "EC2 instance type for backend"
  type        = string
  default     = "t3.nano"
}

variable "keycloak_instance_type" {
  description = "EC2 instance type for keycloak"
  type        = string
  default     = "t3.small"
}

variable "prometheus_instance_type" {
  description = "EC2 instance type for prometheus + grafana"
  type        = string
  default     = "t3.micro"
}


variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Application database name"
  type        = string
  default     = "appdb"
}

variable "keycloak_db_name" {
  description = "Keycloak database name"
  type        = string
  default     = "keycloakdb"
}

variable "db_username" {
  description = "Master DB username"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "domain_name" {
  description = "Internal domain name for Route 53 private hosted zone"
  type        = string
  default     = "internal.dev.eggtive-spm"
}

variable "custom_domain" {
  description = "Custom domain for CloudFront (e.g. dev.spm.eggtive.com, acme.spm.eggtive.com)"
  type        = string
}

variable "root_domain" {
  description = "Root domain for Route 53 zone lookup (e.g. eggtive.com)"
  type        = string
  default     = "eggtive.com"
}

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (infra repo, for Terraform CI/CD)"
  type        = string
}

variable "trusted_apps" {
  description = "Map of app names to their GitHub repo. Each gets a deploy role scoped to its own S3 prefix."
  type = map(object({
    github_repo = string
  }))
  default = {}
}

variable "tenant_name" {
  description = "Display name for the tenant (shown in frontend UI)"
  type        = string
  default     = "SPM"
}

variable "app_workloads" {
  description = <<-EOT
    Generic app instances to provision. Each gets an EC2 with auto-configured systemd service.
    Runtime options: "java21", "java25", "go", "python3", "node20"
    App team stores secrets in SSM under /<project_name>/<environment>/<app-name>/*
    CI uploads artifact to s3://<artifacts-bucket>/<app-name>/<artifact>
  EOT
  type = map(object({
    instance_type = string
    runtime       = string              # java21, java25, go, python3, node20
    artifact      = string              # filename in S3 under <app-name>/ prefix
    port          = number              # app listen port
    metrics_path  = optional(string, "/metrics")
    health_path   = optional(string, "/health")
  }))
  default = {}
}
