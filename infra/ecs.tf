# --- ECS Fargate cluster (shared, always on when container workloads exist) ---

locals {
  active_containers = var.env_active ? var.container_workloads : {}
}

resource "aws_ecs_cluster" "main" {
  count = length(var.container_workloads) > 0 ? 1 : 0
  name  = "${var.project_name}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.project_name}-${var.environment}-ecs" }
}

# --- ECR repos (one per container app, always on) ---
resource "aws_ecr_repository" "app" {
  for_each = var.container_workloads

  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = var.environment == "dev"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project_name}-${each.key}" }
}

# Lifecycle policy — keep last 5 images, expire untagged after 1 day
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = var.container_workloads
  repository = aws_ecr_repository.app[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

# --- Task execution role (shared — pulls images + reads SSM) ---
resource "aws_iam_role" "ecs_execution" {
  count = length(var.container_workloads) > 0 ? 1 : 0
  name  = "${var.project_name}-${var.environment}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_base" {
  count      = length(var.container_workloads) > 0 ? 1 : 0
  role       = aws_iam_role.ecs_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow task execution role to read SSM params (for injecting secrets into containers)
resource "aws_iam_role_policy" "ecs_execution_ssm" {
  count = length(var.container_workloads) > 0 ? 1 : 0
  name  = "ssm-read"
  role  = aws_iam_role.ecs_execution[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/${var.environment}/*"
    }]
  })
}

# --- Task role (shared — what the running container can access) ---
resource "aws_iam_role" "ecs_task" {
  count = length(var.container_workloads) > 0 ? 1 : 0
  name  = "${var.project_name}-${var.environment}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Task role: S3 access for uploads/reports
resource "aws_iam_role_policy" "ecs_task_s3" {
  count = length(var.container_workloads) > 0 ? 1 : 0
  name  = "s3-access"
  role  = aws_iam_role.ecs_task[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.uploads.arn,
        "${aws_s3_bucket.uploads.arn}/*",
        aws_s3_bucket.reports.arn,
        "${aws_s3_bucket.reports.arn}/*"
      ]
    }]
  })
}

# --- Per-app: security group, log group, task definition, ECS service ---

resource "aws_security_group" "container_workload" {
  for_each    = local.active_containers
  name_prefix = "${var.project_name}-${var.environment}-${each.key}-ecs-"
  description = "${each.key} ECS Fargate task"
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

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-ecs" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "container_workload" {
  for_each          = var.container_workloads
  name              = "/${var.project_name}/${var.environment}/ecs/${each.key}"
  retention_in_days = 1
  log_group_class   = "STANDARD"

  tags = { Name = "/${var.project_name}/${var.environment}/ecs/${each.key}" }
}

resource "aws_ecs_task_definition" "app" {
  for_each = local.active_containers

  family                   = "${var.project_name}-${var.environment}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = aws_iam_role.ecs_execution[0].arn
  task_role_arn            = aws_iam_role.ecs_task[0].arn

  container_definitions = jsonencode([
    {
      name      = each.key
      image     = "${aws_ecr_repository.app[each.key].repository_url}:latest"
      essential = true
      portMappings = [{
        containerPort = each.value.port
        protocol      = "tcp"
      }]
      environment = concat(
        [
          { name = "PORT", value = tostring(each.value.port) },
          { name = "OTEL_SERVICE_NAME", value = each.key },
          { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
          { name = "OTEL_RESOURCE_ATTRIBUTES", value = "environment=${var.environment}" },
        ],
        # Auto-instrumentation via env var (Java/Node)
        each.value.runtime == "java21" || each.value.runtime == "java25" ? [
          { name = "JAVA_TOOL_OPTIONS", value = "-javaagent:/otel/opentelemetry-javaagent.jar" }
        ] : [],
        each.value.runtime == "node20" ? [
          { name = "NODE_OPTIONS", value = "--require @opentelemetry/auto-instrumentations-node/register" }
        ] : [],
      )
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/${var.project_name}/${var.environment}/ecs/${each.key}"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = each.key
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${each.value.port}${each.value.health_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}" }
}

resource "aws_lb_target_group" "container_workload" {
  for_each    = local.active_containers
  name_prefix = substr(each.key, 0, 6)
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = each.value.health_path
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-ecs" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "container_workload" {
  for_each     = local.active_containers
  listener_arn = aws_lb_listener.http[0].arn
  priority     = 200 + index(keys(local.active_containers), each.key)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.container_workload[each.key].arn
  }

  condition {
    path_pattern {
      values = ["/${each.key}/*"]
    }
  }
}

resource "aws_ecs_service" "app" {
  for_each = local.active_containers

  name            = each.key
  cluster         = aws_ecs_cluster.main[0].id
  task_definition = aws_ecs_task_definition.app[each.key].arn
  desired_count   = each.value.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.container_workload[each.key].id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.container_workload[each.key].arn
    container_name   = each.key
    container_port   = each.value.port
  }

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}" }
}
