# --- Per-app frontend: S3 + CloudFront + ACM cert + DNS ---

locals {
  # Only apps that define a frontend block get their own CDN
  app_frontends = {
    for k, v in var.container_workloads : k => v.frontend
    if v.frontend != null
  }

  # Resolved domain per app: <env>.<subdomain>.<root_domain>
  app_frontend_domains = {
    for k, v in local.app_frontends : k => "${var.environment}.${v.subdomain}.${var.root_domain}"
  }
}

# --- S3 bucket per app (static frontend assets) ---
resource "aws_s3_bucket" "app_frontend" {
  for_each = local.app_frontends

  bucket        = "${var.project_name}-${var.environment}-${each.key}-frontend"
  force_destroy = var.environment == "dev"

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-frontend" }
}

resource "aws_s3_bucket_versioning" "app_frontend" {
  for_each = local.app_frontends

  bucket = aws_s3_bucket.app_frontend[each.key].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "app_frontend" {
  for_each = local.app_frontends

  bucket = aws_s3_bucket.app_frontend[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- OAC per app ---
resource "aws_cloudfront_origin_access_control" "app_frontend" {
  for_each = local.app_frontends

  name                              = "${var.project_name}-${var.environment}-${each.key}-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- S3 bucket policy for CloudFront OAC ---
resource "aws_s3_bucket_policy" "app_frontend" {
  for_each = local.app_frontends

  bucket = aws_s3_bucket.app_frontend[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.app_frontend[each.key].arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.app[each.key].arn
        }
      }
    }]
  })
}

# --- ACM certificate (us-east-1 for CloudFront) ---
resource "aws_acm_certificate" "app_cdn" {
  for_each = local.app_frontends

  provider          = aws.us_east_1
  domain_name       = local.app_frontend_domains[each.key]
  validation_method = "DNS"

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-cdn-cert" }

  lifecycle { create_before_destroy = true }
}

# --- DNS validation records ---
resource "aws_route53_record" "app_cert_validation" {
  for_each = {
    for item in flatten([
      for app_key, app_val in local.app_frontends : [
        for dvo in aws_acm_certificate.app_cdn[app_key].domain_validation_options : {
          key    = "${app_key}-${dvo.domain_name}"
          name   = dvo.resource_record_name
          record = dvo.resource_record_value
          type   = dvo.resource_record_type
        }
      ]
    ]) : item.key => item
  }

  zone_id = data.aws_route53_zone.domain.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "app_cdn" {
  for_each = local.app_frontends

  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.app_cdn[each.key].arn
  validation_record_fqdns = [
    for dvo in aws_acm_certificate.app_cdn[each.key].domain_validation_options :
    "${dvo.resource_record_name}"
  ]
}

# --- CloudFront distribution per app ---
resource "aws_cloudfront_distribution" "app" {
  for_each = local.app_frontends

  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  comment             = "${var.project_name}-${var.environment}-${each.key}"

  # S3 origin for frontend assets
  origin {
    domain_name              = aws_s3_bucket.app_frontend[each.key].bucket_regional_domain_name
    origin_id                = "s3-${each.key}-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.app_frontend[each.key].id
  }

  # ALB VPC origin for API (only when env is active)
  dynamic "origin" {
    for_each = var.env_active ? [1] : []
    content {
      domain_name = aws_lb.main[0].dns_name
      origin_id   = "alb-${each.key}-backend"
      vpc_origin_config {
        vpc_origin_id            = aws_cloudfront_vpc_origin.alb[0].id
        origin_keepalive_timeout = 5
        origin_read_timeout      = 30
      }
    }
  }

  # Default behavior — SPA from S3
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${each.key}-frontend"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 300
    max_ttl     = 3600
  }

  # /api/* behavior — ALB when active, S3 maintenance fallback when down
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = var.env_active ? "alb-${each.key}-backend" : "s3-${each.key}-frontend"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Host", "Origin"]
      cookies { forward = "all" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # /auth/* behavior — shared Keycloak via ALB
  ordered_cache_behavior {
    path_pattern           = "/auth/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = var.env_active ? "alb-${each.key}-backend" : "s3-${each.key}-frontend"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Host", "Origin"]
      cookies { forward = "all" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  # SPA fallback — serve index.html for client-side routing
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  aliases = [local.app_frontend_domains[each.key]]

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.app_cdn[each.key].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "${var.project_name}-${var.environment}-${each.key}-cdn" }
}

# --- DNS A record pointing subdomain to CloudFront ---
resource "aws_route53_record" "app_cdn" {
  for_each = local.app_frontends

  zone_id = data.aws_route53_zone.domain.zone_id
  name    = local.app_frontend_domains[each.key]
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app[each.key].domain_name
    zone_id                = aws_cloudfront_distribution.app[each.key].hosted_zone_id
    evaluate_target_health = false
  }
}

# --- Runtime config for each app's frontend SPA ---
resource "aws_s3_object" "app_frontend_config" {
  for_each = local.app_frontends

  bucket       = aws_s3_bucket.app_frontend[each.key].id
  key          = "config.json"
  content_type = "application/json"
  content = jsonencode({
    apiBaseUrl = "https://${local.app_frontend_domains[each.key]}/api/${each.key}"
  })
}

# --- CI/CD SSM params (so app's GitHub Actions can find its bucket + distro) ---
resource "aws_ssm_parameter" "app_cicd_frontend_bucket" {
  for_each = local.app_frontends

  name  = "/${var.project_name}/${var.environment}/cicd/${each.key}-frontend-bucket"
  type  = "String"
  value = aws_s3_bucket.app_frontend[each.key].id
}

resource "aws_ssm_parameter" "app_cicd_cloudfront_id" {
  for_each = local.app_frontends

  name  = "/${var.project_name}/${var.environment}/cicd/${each.key}-cloudfront-distribution-id"
  type  = "String"
  value = aws_cloudfront_distribution.app[each.key].id
}
