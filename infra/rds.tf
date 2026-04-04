resource "aws_db_subnet_group" "main" {
  count = var.env_active ? 1 : 0

  name       = "${var.project_name}-${var.environment}-db-subnet"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.project_name}-${var.environment}-db-subnet-group" }
}

resource "aws_db_instance" "main" {
  count = var.env_active ? 1 : 0

  identifier     = "${var.project_name}-${var.environment}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_master[0].result

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = false

  final_snapshot_identifier = "${var.project_name}-${var.environment}-final-${formatdate("YYYYMMDD-hhmmss", timestamp())}"

  tags = { Name = "${var.project_name}-${var.environment}-db" }

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }
}

resource "random_password" "db_master" {
  count   = var.env_active ? 1 : 0
  length  = 32
  special = false
}

# Store DB credentials in SSM
resource "aws_ssm_parameter" "db_password" {
  count = var.env_active ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/db/password"
  type  = "SecureString"
  value = random_password.db_master[0].result
}

resource "aws_ssm_parameter" "db_url" {
  count = var.env_active ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/db/url"
  type  = "SecureString"
  value = "jdbc:postgresql://${aws_db_instance.main[0].endpoint}/${var.db_name}"
}

resource "aws_ssm_parameter" "db_username" {
  count = var.env_active ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/db/username"
  type  = "SecureString"
  value = var.db_username
}

resource "aws_ssm_parameter" "keycloak_db_url" {
  count = var.env_active ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/keycloak/db/url"
  type  = "SecureString"
  value = "jdbc:postgresql://${aws_db_instance.main[0].endpoint}/${var.keycloak_db_name}"
}

resource "aws_ssm_parameter" "keycloak_db_username" {
  count = var.env_active ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/keycloak/db/username"
  type  = "SecureString"
  value = var.db_username
}

resource "aws_ssm_parameter" "keycloak_db_password" {
  count = var.env_active ? 1 : 0

  name  = "/${var.project_name}/${var.environment}/keycloak/db/password"
  type  = "SecureString"
  value = random_password.db_master[0].result
}
