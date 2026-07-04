# S3 gateway endpoint — always on, free
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"

  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project_name}-${var.environment}-s3-endpoint" }
}

# Interface endpoints — on-demand (only when env_active)
locals {
  interface_endpoints = {
    ssm             = "com.amazonaws.${var.aws_region}.ssm"
    ssmmessages     = "com.amazonaws.${var.aws_region}.ssmmessages"
    ec2messages     = "com.amazonaws.${var.aws_region}.ec2messages"
    logs            = "com.amazonaws.${var.aws_region}.logs"
    monitoring      = "com.amazonaws.${var.aws_region}.monitoring"
    bedrock-runtime = "com.amazonaws.${var.aws_region}.bedrock-runtime"
    email-smtp      = "com.amazonaws.${var.aws_region}.email-smtp"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.env_active ? local.interface_endpoints : {}

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-endpoint" }
}
