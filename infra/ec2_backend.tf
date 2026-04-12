

resource "aws_instance" "backend" {
  count = var.env_active ? 1 : 0

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.backend_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.backend[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = base64encode(templatefile("${path.module}/templates/backend_userdata.sh", {
    s3_artifact_bucket = aws_s3_bucket.artifacts.id
    ssm_prefix         = "/${var.project_name}/${var.environment}"
    aws_region         = var.aws_region
    custom_domain      = var.custom_domain
    environment        = var.environment
    reports_bucket     = aws_s3_bucket.reports.id
    uploads_bucket     = aws_s3_bucket.uploads.id
    storage_type       = "s3"
  }))

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-backend"
    Service     = "backend"
    Environment = var.environment
  }

  depends_on = [
    aws_db_instance.main,
    aws_ssm_parameter.db_url,
    aws_ssm_parameter.db_username,
    aws_ssm_parameter.db_password,
    aws_vpc_endpoint.interface,
  ]
}
