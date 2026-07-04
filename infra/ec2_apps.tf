# --- Generic app workload instances ---

locals {
  # Runtime → dnf packages mapping
  runtime_packages = {
    java21  = "java-21-amazon-corretto-headless"
    java25  = "java-25-amazon-corretto-headless"
    go      = ""
    python3 = "python3 python3-pip"
    node20  = "nodejs20"
  }

  # Only create app instances when env is active
  active_workloads = var.env_active ? var.app_workloads : {}
}

resource "aws_security_group" "app_workload" {
  for_each    = local.active_workloads
  name_prefix = "${var.project_name}-${var.environment}-${each.key}-"
  description = "${each.key} app workload"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "App port from VPC"
    protocol    = "tcp"
    from_port   = each.value.port
    to_port     = each.value.port
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "app_workload" {
  for_each = local.active_workloads

  ami                    = data.aws_ami.al2023.id
  instance_type          = each.value.instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.app_workload[each.key].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = base64encode(templatefile("${path.module}/templates/app_userdata.sh", {
    app_name           = each.key
    runtime            = each.value.runtime
    artifact           = each.value.artifact
    s3_artifact_bucket = aws_s3_bucket.artifacts.id
    ssm_prefix         = "/${var.project_name}/${var.environment}"
    aws_region         = var.aws_region
    environment        = var.environment
    project_name       = var.project_name
  }))

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-${each.key}"
    Service     = each.key
    Environment = var.environment
    MetricsPort = tostring(each.value.port)
    MetricsPath = each.value.metrics_path
  }

  depends_on = [
    aws_vpc_endpoint.interface,
  ]
}

# CloudWatch log groups for generic apps
resource "aws_cloudwatch_log_group" "app_workload" {
  for_each = local.active_workloads

  name              = "/${var.project_name}/${var.environment}/${each.key}"
  retention_in_days = 1
  log_group_class   = "STANDARD"

  tags = { Name = "/${var.project_name}/${var.environment}/${each.key}" }
}
