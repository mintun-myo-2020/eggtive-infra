# --- EC2 IAM Role (shared by both instances) ---
resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# SSM access for Session Manager
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# S3 read for pulling artifacts
resource "aws_iam_role_policy" "ec2_s3_read" {
  name = "${var.project_name}-${var.environment}-ec2-s3-read"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*"
      ]
    }]
  })
}

# S3 read/write for reports bucket
resource "aws_iam_role_policy" "ec2_s3_reports" {
  name = "${var.project_name}-${var.environment}-ec2-s3-reports"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.reports.arn,
        "${aws_s3_bucket.reports.arn}/*",
        aws_s3_bucket.uploads.arn,
        "${aws_s3_bucket.uploads.arn}/*"
      ]
    }]
  })
}

# SSM Parameter Store read for secrets
resource "aws_iam_role_policy" "ec2_ssm_params" {
  name = "${var.project_name}-${var.environment}-ec2-ssm-params"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
    }]
  })
}

# CloudWatch Logs
resource "aws_iam_role_policy" "ec2_cloudwatch" {
  name = "${var.project_name}-${var.environment}-ec2-cloudwatch"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms"
        ]
        Resource = "*"
      }
    ]
  })
}

# EC2 describe for Prometheus service discovery
resource "aws_iam_role_policy" "ec2_describe" {
  name = "${var.project_name}-${var.environment}-ec2-describe"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances"
      ]
      Resource = "*"
    }]
  })
}

# SES access for sending emails (Keycloak password reset, etc.)
resource "aws_iam_role_policy" "ec2_ses" {
  name = "${var.project_name}-${var.environment}-ec2-ses"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "arn:aws:ses:${var.aws_region}:*:identity/${var.root_domain}"
    }]
  })
}

# SES SMTP credentials (per-env IAM user for Keycloak SMTP)
resource "aws_iam_user" "ses_smtp" {
  name = "${var.project_name}-${var.environment}-ses-smtp"
  tags = { Name = "${var.project_name}-${var.environment}-ses-smtp" }
}

resource "aws_iam_user_policy" "ses_smtp" {
  name = "ses-send"
  user = aws_iam_user.ses_smtp.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendRawEmail"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}

resource "aws_ssm_parameter" "ses_smtp_username" {
  name  = "/${var.project_name}/${var.environment}/ses/smtp-username"
  type  = "SecureString"
  value = aws_iam_access_key.ses_smtp.id
}

resource "aws_ssm_parameter" "ses_smtp_secret" {
  name  = "/${var.project_name}/${var.environment}/ses/smtp-secret"
  type  = "SecureString"
  value = aws_iam_access_key.ses_smtp.secret
}

# Bedrock access for backend (extraction + LLM)
resource "aws_iam_role_policy" "ec2_bedrock" {
  name = "${var.project_name}-${var.environment}-ec2-bedrock"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# --- GitHub OIDC for CI/CD ---
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# --- Per-app deploy roles (one per trusted app) ---
resource "aws_iam_role" "app_deploy" {
  for_each = var.trusted_apps
  name     = "${var.project_name}-${var.environment}-${each.key}-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${each.value.github_repo}:*" }
      }
    }]
  })
}

# S3: artifacts — scoped to app's prefix only
resource "aws_iam_role_policy" "app_deploy_artifacts" {
  for_each = var.trusted_apps
  name     = "artifacts-s3"
  role     = aws_iam_role.app_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.artifacts.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${each.key}/*"] }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/${each.key}/*"
      }
    ]
  })
}

# S3: frontend bucket (only apps that need frontend deploy get this)
resource "aws_iam_role_policy" "app_deploy_frontend" {
  for_each = var.trusted_apps
  name     = "frontend-s3"
  role     = aws_iam_role.app_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = concat(
        [
          aws_s3_bucket.frontend.arn,
          "${aws_s3_bucket.frontend.arn}/*"
        ],
        # If the app has its own frontend bucket, grant access to that too
        contains(keys(local.app_frontends), each.key) ? [
          aws_s3_bucket.app_frontend[each.key].arn,
          "${aws_s3_bucket.app_frontend[each.key].arn}/*"
        ] : []
      )
    }]
  })
}

# CloudFront: invalidation
resource "aws_iam_role_policy" "app_deploy_cloudfront" {
  for_each = var.trusted_apps
  name     = "cloudfront-invalidation"
  role     = aws_iam_role.app_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudfront:CreateInvalidation", "cloudfront:ListDistributions"]
      Resource = "*"
    }]
  })
}

# SSM: send commands to EC2 for deploy
resource "aws_iam_role_policy" "app_deploy_ssm" {
  for_each = var.trusted_apps
  name     = "ssm-deploy"
  role     = aws_iam_role.app_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
      Resource = [
        "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
      ]
    }]
  })
}

# SSM: read CI/CD parameters
resource "aws_iam_role_policy" "app_deploy_ssm_params" {
  for_each = var.trusted_apps
  name     = "ssm-params"
  role     = aws_iam_role.app_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/${var.environment}/cicd/*"
    }]
  })
}

# ECR: push images (only for apps that have a container_workload)
resource "aws_iam_role_policy" "app_deploy_ecr" {
  for_each = { for k, v in var.trusted_apps : k => v if contains(keys(var.container_workloads), k) }
  name     = "ecr-push"
  role     = aws_iam_role.app_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = aws_ecr_repository.app[each.key].arn
      }
    ]
  })
}

# ECS: force new deployment (only for apps that have a container_workload)
resource "aws_iam_role_policy" "app_deploy_ecs" {
  for_each = { for k, v in var.trusted_apps : k => v if contains(keys(var.container_workloads), k) }
  name     = "ecs-deploy"
  role     = aws_iam_role.app_deploy[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecs:UpdateService",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition"
      ]
      Resource = "*"
      Condition = {
        StringEquals = {
          "ecs:cluster" = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.project_name}-${var.environment}"
        }
      }
    }]
  })
}

# --- Infra repo role (for Terraform CI/CD — separate from app deploys) ---
resource "aws_iam_role" "infra_cicd" {
  name = "${var.project_name}-${var.environment}-infra-cicd"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*" }
      }
    }]
  })
}

# Terraform state access (infra repo only)
resource "aws_iam_role_policy" "infra_cicd_terraform" {
  name = "terraform-state"
  role = aws_iam_role.infra_cicd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.project_name}-terraform-state",
          "arn:aws:s3:::${var.project_name}-terraform-state/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/terraform-locks"
      }
    ]
  })
}

# Artifacts S3 access (infra repo uploads shared config like Keycloak realm exports)
resource "aws_iam_role_policy" "infra_cicd_artifacts" {
  name = "artifacts-s3"
  role = aws_iam_role.infra_cicd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.artifacts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      }
    ]
  })
}

# Full infrastructure management (Terraform needs to read/write all managed resources)
resource "aws_iam_role_policy" "infra_cicd_manage" {
  name = "infra-manage"
  role = aws_iam_role.infra_cicd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EC2"
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = "*"
      },
      {
        Sid      = "ECS"
        Effect   = "Allow"
        Action   = ["ecs:*", "ecr:*"]
        Resource = "*"
      },
      {
        Sid      = "LoadBalancing"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:*"]
        Resource = "*"
      },
      {
        Sid      = "CloudFront"
        Effect   = "Allow"
        Action   = ["cloudfront:*"]
        Resource = "*"
      },
      {
        Sid      = "ACM"
        Effect   = "Allow"
        Action   = ["acm:*"]
        Resource = "*"
      },
      {
        Sid      = "Route53"
        Effect   = "Allow"
        Action   = ["route53:*", "route53domains:*"]
        Resource = "*"
      },
      {
        Sid      = "S3"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      },
      {
        Sid      = "RDS"
        Effect   = "Allow"
        Action   = ["rds:*"]
        Resource = "*"
      },
      {
        Sid      = "IAM"
        Effect   = "Allow"
        Action   = ["iam:*"]
        Resource = "*"
      },
      {
        Sid      = "SSM"
        Effect   = "Allow"
        Action   = ["ssm:*"]
        Resource = "*"
      },
      {
        Sid      = "CloudWatch"
        Effect   = "Allow"
        Action   = ["logs:*", "cloudwatch:*"]
        Resource = "*"
      },
      {
        Sid      = "SES"
        Effect   = "Allow"
        Action   = ["ses:*"]
        Resource = "*"
      },
      {
        Sid      = "Bedrock"
        Effect   = "Allow"
        Action   = ["bedrock:*"]
        Resource = "*"
      }
    ]
  })
}

