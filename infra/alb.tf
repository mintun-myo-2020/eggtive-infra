resource "aws_lb" "main" {
  count = var.env_active ? 1 : 0

  name               = "${var.project_name}-${var.environment}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = aws_subnet.private[*].id

  tags = { Name = "${var.project_name}-${var.environment}-alb" }
}

resource "aws_lb_listener" "http" {
  count = var.env_active ? 1 : 0

  load_balancer_arn = aws_lb.main[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\": \"not found\"}"
      status_code  = "404"
    }
  }
}

# --- Backend target group ---
resource "aws_lb_target_group" "backend" {
  count = var.env_active ? 1 : 0

  name     = "${var.project_name}-${var.environment}-backend-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/actuator/health"
    port                = "8080"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.project_name}-${var.environment}-backend-tg" }
}

resource "aws_lb_target_group_attachment" "backend" {
  count = var.env_active ? 1 : 0

  target_group_arn = aws_lb_target_group.backend[0].arn
  target_id        = aws_instance.backend[0].id
  port             = 8080
}

resource "aws_lb_listener_rule" "backend" {
  count = var.env_active ? 1 : 0

  listener_arn = aws_lb_listener.http[0].arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend[0].arn
  }

  condition {
    path_pattern { values = ["/api/*"] }
  }
}

# --- Keycloak target group ---
resource "aws_lb_target_group" "keycloak" {
  count = var.env_active ? 1 : 0

  name     = "${var.project_name}-${var.environment}-kc-tg"
  port     = 8443
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/auth/health/ready"
    port                = "9000"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = { Name = "${var.project_name}-${var.environment}-keycloak-tg" }
}

resource "aws_lb_target_group_attachment" "keycloak" {
  count = var.env_active ? 1 : 0

  target_group_arn = aws_lb_target_group.keycloak[0].arn
  target_id        = aws_instance.keycloak[0].id
  port             = 8443
}

resource "aws_lb_listener_rule" "keycloak" {
  count = var.env_active ? 1 : 0

  listener_arn = aws_lb_listener.http[0].arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak[0].arn
  }

  condition {
    path_pattern { values = ["/auth/*"] }
  }
}
