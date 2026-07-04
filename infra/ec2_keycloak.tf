resource "aws_instance" "keycloak" {
  count = var.env_active ? 1 : 0

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.keycloak_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.keycloak[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = base64encode(templatefile("${path.module}/templates/keycloak_userdata.sh", {
    s3_artifact_bucket = aws_s3_bucket.artifacts.id
    ssm_prefix         = "/${var.project_name}/${var.environment}"
    aws_region         = var.aws_region
    environment        = var.environment
    project_name       = var.project_name
    custom_domain      = var.custom_domain
    root_domain        = var.root_domain
  }))

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-keycloak"
    Service     = "keycloak"
    Environment = var.environment
    MetricsPort = "9000"
    MetricsPath = "/auth/metrics"
  }

  depends_on = [
    aws_db_instance.main,
    aws_ssm_parameter.keycloak_db_url,
    aws_ssm_parameter.keycloak_db_username,
    aws_ssm_parameter.keycloak_db_password,
    aws_ssm_parameter.ses_smtp_username,
    aws_ssm_parameter.ses_smtp_secret,
    aws_vpc_endpoint.interface,
  ]
}
