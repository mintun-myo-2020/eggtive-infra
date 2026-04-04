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
