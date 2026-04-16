# --- Frontend assets bucket (per env, always on) ---
resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.project_name}-${var.environment}-frontend"
  force_destroy = var.environment == "dev"

  tags = { Name = "${var.project_name}-${var.environment}-frontend" }
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Maintenance page for when env is down
resource "aws_s3_object" "maintenance_api" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "api/maintenance.json"
  content      = jsonencode({ status = "maintenance", message = "Environment is offline" })
  content_type = "application/json"
}

resource "aws_s3_object" "maintenance_auth" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "auth/maintenance.json"
  content      = jsonencode({ status = "maintenance", message = "Environment is offline" })
  content_type = "application/json"
}

# Runtime config for frontend SPA — fetched on app load instead of build-time env vars
resource "aws_s3_object" "frontend_config" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "config.json"
  content_type = "application/json"
  content = jsonencode({
    apiBaseUrl       = "https://${var.custom_domain}/api/v1"
    keycloakUrl      = "https://${var.custom_domain}/auth"
    keycloakRealm    = "spm"
    keycloakClientId = "spm-frontend"
  })
}

# --- Uploads bucket (per env, always on) ---
resource "aws_s3_bucket" "uploads" {
  bucket        = "${var.project_name}-${var.environment}-uploads"
  force_destroy = var.environment == "dev"

  tags = { Name = "${var.project_name}-${var.environment}-uploads" }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Reports bucket (per env, always on) ---
resource "aws_s3_bucket" "reports" {
  bucket        = "${var.project_name}-${var.environment}-reports"
  force_destroy = var.environment == "dev"

  tags = { Name = "${var.project_name}-${var.environment}-reports" }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Artifacts bucket (shared, always on) ---
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.project_name}-artifacts"
  force_destroy = var.environment == "dev"

  tags = { Name = "${var.project_name}-artifacts" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
