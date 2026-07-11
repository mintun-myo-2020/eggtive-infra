# CloudWatch Log Groups — infrequent access, 1 day retention
locals {
  log_groups = var.env_active ? toset([
    "/${var.project_name}/${var.environment}/backend",
    "/${var.project_name}/${var.environment}/keycloak",
    "/${var.project_name}/${var.environment}/prometheus",
    "/${var.project_name}/${var.environment}/userdata",
  ]) : toset([])
}

import {
  for_each = local.log_groups
  to       = aws_cloudwatch_log_group.services[each.value]
  id       = each.value
}

resource "aws_cloudwatch_log_group" "services" {
  for_each = local.log_groups

  name              = each.value
  retention_in_days = 1
  log_group_class   = "STANDARD"

  tags = { Name = each.value }
}
