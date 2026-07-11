# --- Per-app RDS instances (for container workloads with database config) ---

locals {
  # Only apps that define a database block get an RDS instance
  app_databases = {
    for k, v in var.container_workloads : k => v.database
    if v.database != null
  }

  # Only provision when env is active
  active_app_databases = var.env_active ? local.app_databases : {}
}

# --- DB subnet group (shared across all per-app databases) ---
resource "aws_db_subnet_group" "app" {
  count = length(local.app_databases) > 0 && var.env_active ? 1 : 0

  name       = "${var.project_name}-${var.environment}-app-db-subnet"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.project_name}-${var.environment}-app-db-subnet-group" }
}

# --- Security group per app database ---
resource "aws_security_group" "app_rds" {
  for_each = local.active_app_databases

  name_prefix = "${var.project_name}-${var.environment}-${each.key}-rds-"
  description = "${each.key} RDS - allow inbound from ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from ${each.key} ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.container_workload[each.key].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-rds" }

  lifecycle { create_before_destroy = true }
}

# --- Random password per app ---
resource "random_password" "app_db" {
  for_each = local.active_app_databases

  length  = 32
  special = false
}

# --- RDS instance per app ---
resource "aws_db_instance" "app" {
  for_each = local.active_app_databases

  identifier     = "${var.project_name}-${var.environment}-${each.key}-db"
  engine         = each.value.engine
  engine_version = each.value.engine_version
  instance_class = each.value.instance_class

  allocated_storage     = each.value.storage_gb
  max_allocated_storage = each.value.max_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = each.value.db_name
  username = each.value.username
  password = random_password.app_db[each.key].result

  db_subnet_group_name   = aws_db_subnet_group.app[0].name
  vpc_security_group_ids = [aws_security_group.app_rds[each.key].id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = false

  final_snapshot_identifier = "${var.project_name}-${var.environment}-${each.key}-final-${formatdate("YYYYMMDD", timestamp())}"

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-db" }

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }
}

# --- Store credentials in SSM (app reads these at runtime) ---
# DB_URL format depends on runtime:
#   java21/java25 → jdbc:postgresql://host:port/dbname
#   go/node20/python3 → postgres://user:pass@host:port/dbname
resource "aws_ssm_parameter" "app_db_url" {
  for_each = local.active_app_databases

  name = "/${var.project_name}/${var.environment}/${each.key}/db/url"
  type = "SecureString"
  value = (
    contains(["java21", "java25"], try(var.container_workloads[each.key].runtime, ""))
    ? "jdbc:postgresql://${aws_db_instance.app[each.key].endpoint}/${each.value.db_name}"
    : "postgres://${each.value.username}:${random_password.app_db[each.key].result}@${aws_db_instance.app[each.key].endpoint}/${each.value.db_name}"
  )
}

resource "aws_ssm_parameter" "app_db_username" {
  for_each = local.active_app_databases

  name  = "/${var.project_name}/${var.environment}/${each.key}/db/username"
  type  = "SecureString"
  value = each.value.username
}

resource "aws_ssm_parameter" "app_db_password" {
  for_each = local.active_app_databases

  name  = "/${var.project_name}/${var.environment}/${each.key}/db/password"
  type  = "SecureString"
  value = random_password.app_db[each.key].result
}

# --- Internal DNS record for each app's database ---
resource "aws_route53_record" "app_db" {
  for_each = local.active_app_databases

  zone_id = aws_route53_zone.internal.zone_id
  name    = "${each.key}-db.${var.domain_name}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.app[each.key].address]
}
