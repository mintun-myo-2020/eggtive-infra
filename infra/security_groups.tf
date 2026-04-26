# --- VPC Endpoints SG (always created, referenced by endpoints when active) ---
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.project_name}-${var.environment}-vpce-"
  description = "Allow HTTPS from VPC to VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "SES SMTP (TLS wrapper) from VPC"
    from_port   = 465
    to_port     = 465
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "SES SMTP (STARTTLS) from VPC"
    from_port   = 587
    to_port     = 587
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-vpce-sg" }

  lifecycle { create_before_destroy = true }
}

# --- ALB SG ---
resource "aws_security_group" "alb" {
  count = var.env_active ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-alb-"
  description = "ALB - allow inbound from CloudFront"
  vpc_id      = aws_vpc.main.id

  # CloudFront managed prefix list (works with both VPC origins and regular origins)
  ingress {
    description     = "HTTP from CloudFront"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-alb-sg" }

  lifecycle { create_before_destroy = true }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# --- Backend EC2 SG ---
resource "aws_security_group" "backend" {
  count = var.env_active ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-backend-"
  description = "Backend EC2 - allow inbound from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb[0].id, aws_security_group.prometheus[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-backend-sg" }

  lifecycle { create_before_destroy = true }
}

# --- Keycloak EC2 SG ---
resource "aws_security_group" "keycloak" {
  count = var.env_active ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-keycloak-"
  description = "Keycloak EC2 - allow inbound from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Keycloak port from ALB and backend"
    from_port       = 8443
    to_port         = 8443
    protocol        = "tcp"
    security_groups = [aws_security_group.alb[0].id, aws_security_group.backend[0].id, aws_security_group.prometheus[0].id]
  }

  ingress {
    description     = "Keycloak management port (health + metrics) from ALB and Prometheus"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb[0].id, aws_security_group.prometheus[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-keycloak-sg" }

  lifecycle { create_before_destroy = true }
}

# --- Prometheus SG ---
resource "aws_security_group" "prometheus" {
  count       = var.env_active ? 1 : 0
  name_prefix = "${var.project_name}-${var.environment}-prometheus-"
  description = "Prometheus EC2"

  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow access from VPC CIDR"
    protocol    = "tcp"
    from_port   = 9090
    to_port     = 9090
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-prometheus-sg" }

  lifecycle { create_before_destroy = true }
}

# --- RDS SG ---
resource "aws_security_group" "rds" {
  count = var.env_active ? 1 : 0

  name_prefix = "${var.project_name}-${var.environment}-rds-"
  description = "RDS - allow inbound from backend and keycloak EC2s"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from backend"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend[0].id]
  }

  ingress {
    description     = "Postgres from keycloak"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.keycloak[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-rds-sg" }

  lifecycle { create_before_destroy = true }
}
