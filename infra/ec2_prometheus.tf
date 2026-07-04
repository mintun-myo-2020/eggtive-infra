resource "aws_instance" "prometheus" {
  count                  = var.env_active ? 1 : 0
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.prometheus_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.prometheus[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = base64encode(templatefile("${path.module}/templates/prometheus_userdata.sh", {
    s3_artifact_bucket = aws_s3_bucket.artifacts.id
    ssm_prefix         = "/${var.project_name}/${var.environment}"
    aws_region         = var.aws_region
    environment        = var.environment
    project_name       = var.project_name
    domain_name        = var.domain_name
  }))

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-prometheus"
    Service     = "prometheus"
    Environment = var.environment
  }
}
