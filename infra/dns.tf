# Route 53 Private Hosted Zone — always on
resource "aws_route53_zone" "internal" {
  name = var.domain_name

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = { Name = "${var.project_name}-${var.environment}-internal-zone" }
}

# A records — only when env is active
resource "aws_route53_record" "backend" {
  count = var.env_active ? 1 : 0

  zone_id = aws_route53_zone.internal.zone_id
  name    = "backend.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.backend[0].private_ip]
}

resource "aws_route53_record" "keycloak" {
  count = var.env_active ? 1 : 0

  zone_id = aws_route53_zone.internal.zone_id
  name    = "keycloak.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.keycloak[0].private_ip]
}

resource "aws_route53_record" "db" {
  count = var.env_active ? 1 : 0

  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.${var.domain_name}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.main[0].address]
}

resource "aws_route53_record" "prometheus" {
  count   = var.env_active ? 1 : 0
  zone_id = aws_route53_zone.internal.zone_id
  name    = "prometheus.${var.domain_name}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.prometheus[0].private_ip]
}

