# Architecture Explained — Eggtive SPM

This document explains the what, why, and how of every architectural decision
in this infrastructure with specific implementation details.
Read ARCHITECTURE.md for the visual diagrams.
Read ARCHITECTURE-RESOURCES.md for per-resource configuration reference.

---

## What Is This?

A full-stack web application running on AWS:
- React frontend (SPA)
- JVM backend (Spring Boot, JDK 25)
- Keycloak identity provider (JDK 21)
- PostgreSQL 16 database (RDS)

Two separate repos:
- This repo (`spm-infra`) — Terraform code that creates and manages all AWS resources
- App repo (`spm`) — application source code with CI/CD workflows that build and deploy

---

## Why This Architecture?

### Why CloudFront in front of everything?

CloudFront is the only thing exposed to the internet. Everything else is private.

Specifically, in `cloudfront.tf`, the distribution has three cache behaviors:

```
default (/*):
  target_origin_id = "s3-frontend"
  → serves React SPA from S3 bucket eggtive-spm-dev-frontend
  → cached for 24hrs (default_ttl = 86400)

/api/*:
  target_origin_id = var.env_active ? "alb-backend" : "s3-frontend"
  → when env is up: proxies to internal ALB → backend EC2 port 8080
  → when env is down: serves api/maintenance.json from S3
  → TTL = 0 (no caching — API responses are dynamic)
  → forwards: Authorization header, Host, Origin, all cookies, query strings

/auth/*:
  target_origin_id = var.env_active ? "alb-backend" : "s3-frontend"
  → when env is up: proxies to internal ALB → keycloak EC2 port 8443
  → when env is down: serves auth/maintenance.json from S3
  → TTL = 0, same forwarding as /api/*
```

The `dynamic "origin"` block in `cloudfront.tf` conditionally adds the ALB origin
using CloudFront VPC origins (which create an ENI inside the VPC to reach the
internal ALB):
```hcl
resource "aws_cloudfront_vpc_origin" "alb" {
  count = var.env_active ? 1 : 0
  vpc_origin_endpoint_config {
    arn                    = aws_lb.main[0].arn
    http_port              = 80
    origin_protocol_policy = "http-only"
  }
  depends_on = [aws_internet_gateway.main]
}

dynamic "origin" {
  for_each = var.env_active ? [1] : []
  content {
    domain_name = aws_lb.main[0].dns_name
    origin_id   = "alb-backend"
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.alb[0].id
    }
  }
}
```

When `env_active = false`, this origin doesn't exist, so `/api/*` and `/auth/*`
fall back to the S3 origin which serves the maintenance JSON files.

The SPA fallback handles React client-side routing:
```hcl
custom_error_response {
  error_code = 403          # S3 returns 403 for non-existent keys
  response_code = 200       # CloudFront converts it to 200
  response_page_path = "/index.html"  # and serves index.html
}
```
This means `spm.eggtive.com/dashboard`, `spm.eggtive.com/settings`, etc. all
serve `index.html` and React Router handles the path client-side.

### Why no public subnets?

In `vpc.tf`, there are only private subnets. There is no `aws_nat_gateway`,
and no route to `0.0.0.0/0` in the route table.

An `aws_internet_gateway` is attached to the VPC, but this is solely a
requirement of CloudFront VPC origins — AWS mandates an IGW exists on the VPC
even though no route table references it. No traffic flows through it.

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id  # attached but no routes point to it
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  # no routes defined — only implicit local route (10.0.0.0/16)
  # and S3 gateway endpoint route (added automatically)
}
```

The EC2 instances literally cannot send or receive traffic to/from the internet.
The only way traffic enters the VPC is through CloudFront → VPC origin ENI → ALB.
The only way EC2 talks to AWS services is through VPC endpoints.

### Why VPC endpoints instead of a NAT gateway?

In `vpc_endpoints.tf`, there are two types:

**S3 Gateway Endpoint (always on, free):**
```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
```
This adds a route in the private route table that sends S3-bound traffic
directly to S3 over the AWS backbone. It's how EC2 runs `aws s3 cp` and
`dnf install` (AL2023 repos are hosted on S3) without internet access.

**Interface Endpoints (on-demand, $7.20/mo each):**
```hcl
for_each = var.env_active ? local.interface_endpoints : {}
```
Four endpoints, only created when `env_active = true`:
- `ssm` — SSM API (parameter store reads, session manager)
- `ssmmessages` — SSM Session Manager WebSocket connections
- `ec2messages` — SSM agent polling for run-commands
- `logs` — CloudWatch Logs API

Each has `private_dns_enabled = true`, which means when EC2 calls
`ssm.ap-southeast-1.amazonaws.com`, DNS resolves to the endpoint's
private IP inside the VPC, not the public IP. Traffic stays internal.

### Why separate EC2 instances for backend and Keycloak?

In `ec2_backend.tf` and `ec2_keycloak.tf`, each is a separate `aws_instance`
with its own security group:

```hcl
# ec2_backend.tf
resource "aws_instance" "backend" {
  vpc_security_group_ids = [aws_security_group.backend[0].id]  # only ALB→8080
  tags = { Service = "backend" }
}

# ec2_keycloak.tf
resource "aws_instance" "keycloak" {
  vpc_security_group_ids = [aws_security_group.keycloak[0].id]  # only ALB→8443
  tags = { Service = "keycloak" }
}
```

The security groups are specific:
- `backend` SG: ingress TCP 8080 from ALB SG only
- `keycloak` SG: ingress TCP 8443 from ALB SG only
- Neither can talk to the other directly — they communicate through DNS/ALB

The `Service` tag is how CI/CD targets deploys:
```bash
aws ssm send-command --targets "Key=tag:Service,Values=backend"
```
This works regardless of instance ID — if the instance is replaced, the tag
is on the new one and the deploy still works.

### Why JVM directly on EC2 instead of Docker?

The user data scripts in `templates/backend_userdata.sh` and
`templates/keycloak_userdata.sh` install JDK and run JARs via systemd:

```bash
# backend_userdata.sh
dnf install -y java-25-amazon-corretto-headless
# ...
ExecStart=/usr/bin/java -jar /opt/app/backend.jar

# keycloak_userdata.sh
dnf install -y java-21-amazon-corretto-headless
# ...
ExecStart=/opt/keycloak/bin/kc.sh start
```

No Docker means:
- No ECR repository needed (saves the resource)
- No ECR VPC endpoints needed (saves 2 × $7.20/mo = $14.40/mo)
- Artifacts stored in S3 instead (free via gateway endpoint)
- Deploy is `aws s3 cp` + `systemctl restart` instead of `docker pull` + `docker-compose up`

### Why an internal ALB?

In `alb.tf`:
```hcl
resource "aws_lb" "main" {
  internal           = true   # no public IP
  load_balancer_type = "application"
  subnets            = aws_subnet.private[*].id  # both AZs
}
```

The ALB listener is HTTP on port 80:
```hcl
resource "aws_lb_listener" "http" {
  port     = 80
  protocol = "HTTP"
  default_action { type = "fixed-response"; status_code = "404" }
}
```

Two listener rules route by path:
- Priority 100: `/api/*` → backend target group (port 8080)
- Priority 200: `/auth/*` → keycloak target group (port 8443)
- Default: 404 JSON response (anything else is a misconfiguration)

The ALB security group (`security_groups.tf`) allows port 80 from the CloudFront
managed prefix list:
```hcl
ingress {
  from_port       = 80
  prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
}
```
AWS maintains this prefix list with all CloudFront IPs. CloudFront VPC origins
connect via a managed ENI in the private subnet, and the traffic is tagged with
CloudFront's prefix list IPs. The ALB remains internal with no public IP.

### Why Route 53 Private Hosted Zone? (How DNS survives instance replacement)

In `dns.tf`, the private zone is always on, but the records are on-demand:

```hcl
resource "aws_route53_zone" "internal" {
  name = "internal.dev.eggtive-spm"
  vpc { vpc_id = aws_vpc.main.id }  # only resolvable inside this VPC
}

resource "aws_route53_record" "backend" {
  count   = var.env_active ? 1 : 0
  name    = "backend.internal.dev.eggtive-spm"
  type    = "A"
  records = [aws_instance.backend[0].private_ip]  # ← Terraform reference
}
```

That `aws_instance.backend[0].private_ip` is the key. It's not a hardcoded
value — Terraform evaluates it at apply time. Here's exactly what happens:

**First `make up`:**
1. Terraform creates `aws_instance.backend[0]` → AWS assigns IP `10.0.1.47`
2. Terraform evaluates `aws_instance.backend[0].private_ip` → resolves to `10.0.1.47`
3. Terraform creates Route 53 A record: `backend.internal.dev.eggtive-spm → 10.0.1.47`
4. Terraform creates `aws_instance.keycloak[0]` → AWS assigns IP `10.0.1.83`
5. Terraform creates A record: `keycloak.internal.dev.eggtive-spm → 10.0.1.83`
6. Terraform creates RDS → endpoint is `eggtive-spm-dev-db.abc123.ap-southeast-1.rds.amazonaws.com`
7. Terraform creates CNAME: `db.internal.dev.eggtive-spm → eggtive-spm-dev-db.abc123...`

**`make down` then `make up` again:**
1. `make down` destroys EC2s, RDS, and all DNS records (all have `count = var.env_active ? 1 : 0`)
2. `make up` creates new EC2s → AWS assigns `10.0.1.112` and `10.0.1.29` (different IPs)
3. Terraform creates new DNS records with the new IPs automatically

**Why the app config never changes:**

The backend's SSM parameter for Keycloak URL is:
```
/eggtive-spm/dev/keycloak/url = http://keycloak.internal.dev.eggtive-spm:8443/auth/realms/master
```

This uses the DNS name, not an IP. At runtime:
```
Backend reads SSM → gets "keycloak.internal.dev.eggtive-spm"
  → Route 53 resolves to 10.0.1.29 (current keycloak IP)
  → backend connects to keycloak
```

If keycloak EC2 is replaced (tainted, crashed, make down/up), the IP changes
but the DNS name stays the same. Terraform updates the A record. The backend
resolves the new IP on next connection (TTL is 60 seconds).

Same for the database:
```
Backend reads SSM → gets "jdbc:postgresql://eggtive-spm-dev-db.abc123...:5432/appdb"
  → also available as db.internal.dev.eggtive-spm (CNAME)
  → RDS endpoint resolves to current DB IP
```

The SSM parameters for DB URL are also on-demand (`count = var.env_active ? 1 : 0`).
When `make up` creates a new RDS, Terraform writes the new endpoint to SSM:
```hcl
resource "aws_ssm_parameter" "db_url" {
  count = var.env_active ? 1 : 0
  name  = "/${var.project_name}/${var.environment}/db/url"
  value = "jdbc:postgresql://${aws_db_instance.main[0].endpoint}/${var.db_name}"
}
```

The EC2 user data reads this at boot time, so it always gets the current RDS endpoint.

### Why SSM Session Manager instead of SSH?

There are zero inbound ports on either EC2 security group for SSH:
```hcl
# security_groups.tf — backend SG
ingress {
  from_port       = 8080      # only app port
  security_groups = [aws_security_group.alb[0].id]  # only from ALB
}
# no port 22 rule exists
```

SSM Session Manager works through the VPC interface endpoints:
```
Developer laptop
  → aws ssm start-session --target i-0abc123
  → AWS SSM API (internet)
  → SSM VPC endpoint (ssm, ssmmessages, ec2messages)
  → SSM agent on EC2 (pre-installed on AL2023)
  → shell session
```

The EC2's IAM role has `AmazonSSMManagedInstanceCore` attached, which gives
the SSM agent permission to communicate with the SSM service through the
VPC endpoints.

No SSH keys, no bastion host, no port 22. Every session is logged in CloudTrail.

### Why on-demand (make up / make down)? (How the toggle works internally)

Every expensive resource uses `count = var.env_active ? 1 : 0`:

```hcl
# ec2_backend.tf
resource "aws_instance" "backend" {
  count = var.env_active ? 1 : 0   # exists when true, destroyed when false
}

# rds.tf
resource "aws_db_instance" "main" {
  count = var.env_active ? 1 : 0
}

# alb.tf
resource "aws_lb" "main" {
  count = var.env_active ? 1 : 0
}

# vpc_endpoints.tf
resource "aws_vpc_endpoint" "interface" {
  for_each = var.env_active ? local.interface_endpoints : {}  # map version of count
}
```

The Makefile passes the variable:
```makefile
up:
    terraform apply -var-file=envs/dev.tfvars -var="env_active=true" -auto-approve

down:
    terraform apply -var-file=envs/dev.tfvars -var="env_active=false" -auto-approve
```

**What `make down` actually does (in order):**
1. Terraform sees `env_active = false`
2. All resources with `count = var.env_active ? 1 : 0` evaluate to `count = 0`
3. Terraform plans to destroy: 2 EC2s, 1 RDS (takes final snapshot), 1 ALB,
   2 target groups, 2 listener rules, 4 VPC interface endpoints, 3 DNS records,
   6 SSM parameters (DB-related), 1 DB subnet group, 4 security groups (ALB, backend, keycloak, RDS)
4. CloudFront distribution is updated: ALB VPC origin removed, `/api/*` and `/auth/*`
   behaviors switch `target_origin_id` from `"alb-backend"` to `"s3-frontend"`
5. Resources that don't have `count` stay untouched: VPC, subnets, IGW, S3 buckets,
   CloudFront, IAM roles, SSM keycloak admin password, Route 53 zone, ACM cert

**What `make up` actually does (in order):**
1. Terraform sees `env_active = true`
2. All `count = 0` resources become `count = 1` — Terraform plans to create them
3. Creates in dependency order: security groups → VPC endpoints → RDS → DB subnet group
   → SSM parameters (with new RDS endpoint) → EC2s (user data reads SSM) → ALB →
   target groups → listener rules → DNS records (with new EC2 IPs)
4. CloudFront updated: ALB VPC origin created, behaviors switch back to `"alb-backend"`
5. EC2 user data runs: installs JDK, pulls artifacts from S3, reads SSM, starts services

### Why GitHub OIDC instead of AWS access keys? (How it works specifically)

In `iam.tf`, the OIDC provider is registered:
```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
```

The IAM role trusts tokens from this provider, but only from your specific repo:
```hcl
resource "aws_iam_role" "github_actions" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:mintun-myo-2020/spm:*"
        }
      }
    }]
  })
}
```

**The flow on every CI run:**
1. GitHub Actions workflow has `permissions: { id-token: write }`
2. The `aws-actions/configure-aws-credentials@v4` step requests an OIDC token from GitHub
3. GitHub generates a JWT with `sub = "repo:mintun-myo-2020/spm:ref:refs/heads/main"`
4. The action calls `sts:AssumeRoleWithWebIdentity` with this JWT
5. AWS checks: is the `aud` claim `sts.amazonaws.com`? ✓
6. AWS checks: does the `sub` claim match `repo:mintun-myo-2020/spm:*`? ✓
7. AWS issues temporary credentials (valid ~1 hour)
8. CI uses these credentials for S3, CloudFront, SSM operations

No long-lived keys anywhere. If someone forks your repo, the `sub` claim
would be `repo:attacker/fork:*` which doesn't match the trust policy.

---

## How It Works

### How does a frontend deploy work? (Step by step)

```
1. Developer pushes to main branch (frontend/ directory changed)
2. GitHub Actions workflow triggers (path filter: frontend/**)
3. Workflow requests OIDC token → assumes eggtive-spm-dev-github-actions role
4. npm ci → npm run build → produces build/ directory
5. aws s3 sync build/ s3://eggtive-spm-dev-frontend/ --delete
   → uploads new files, deletes old ones not in build/
   → goes through S3 API (internet from GitHub runner, not through VPC)
6. aws cloudfront create-invalidation --paths "/*"
   → finds distribution by comment "eggtive-spm-dev"
   → invalidates all cached files at edge locations
7. Next request to spm.eggtive.com → CloudFront fetches new files from S3
```

The S3 bucket policy only allows CloudFront OAC to read:
```hcl
Condition = {
  StringEquals = {
    "AWS:SourceArn" = aws_cloudfront_distribution.main.arn
  }
}
```
CI can write to S3 (via the github_s3 IAM policy), but only CloudFront can read.
Direct S3 URLs return 403.

### How does a backend deploy work? (Step by step)

```
1. Developer pushes to main branch (backend/ directory changed)
2. GitHub Actions workflow triggers
3. OIDC auth → assumes IAM role
4. gradle build → produces spm-app.jar
5. aws s3 cp spm-app.jar s3://eggtive-spm-artifacts/spm-app.jar
6. aws ssm send-command \
     --document-name "AWS-RunShellScript" \
     --targets "Key=tag:Service,Values=backend" "Key=tag:Environment,Values=dev" \
     --parameters 'commands=["bash /opt/deploy/deploy.sh"]'
```

The SSM command targets by tag, not instance ID. This is critical because
instance IDs change on every `make up`. The tags are set in Terraform:
```hcl
tags = {
  Service     = "backend"
  Environment = var.environment  # "dev"
}
```

**What deploy.sh does on the EC2:**
```bash
aws s3 cp "s3://eggtive-spm-artifacts/spm-app.jar" /opt/app/backend.jar
chown appuser:appuser /opt/app/backend.jar
systemctl restart backend
```

The S3 download uses the S3 gateway VPC endpoint (free, on backbone).
The EC2's IAM role has `s3:GetObject` on the artifacts bucket.

**If the EC2 is down (env_active = false):**
- Step 5 succeeds (JAR uploaded to S3)
- Step 6 fails silently (no instances match the tag filter)
- Next `make up` → EC2 user data pulls the latest JAR from S3 automatically

### How do secrets work? (The full chain)

**Terraform creates secrets:**
```hcl
# rds.tf — auto-generated DB password
resource "random_password" "db_master" {
  count   = var.env_active ? 1 : 0
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "db_password" {
  count = var.env_active ? 1 : 0
  name  = "/eggtive-spm/dev/db/password"
  type  = "SecureString"
  value = random_password.db_master[0].result
}
```

**EC2 user data reads secrets at boot:**
```bash
# templates/backend_userdata.sh
DB_PASSWORD=$(aws ssm get-parameter \
  --name "/eggtive-spm/dev/db/password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ap-southeast-1)
```

This works because:
1. The EC2 has IAM instance profile `eggtive-spm-dev-ec2-profile`
2. That profile's role has policy `ec2_ssm_params` allowing `ssm:GetParameter`
   on `arn:aws:ssm:ap-southeast-1:*:parameter/eggtive-spm/dev/*`
3. The SSM API call goes through the SSM VPC interface endpoint (private, on backbone)
4. `--with-decryption` decrypts the SecureString using the default AWS KMS key

**The secrets are written to an env file:**
```bash
cat > /opt/app/backend.env <<EOF
SPRING_DATASOURCE_URL=$DB_URL
SPRING_DATASOURCE_USERNAME=$DB_USERNAME
SPRING_DATASOURCE_PASSWORD=$DB_PASSWORD
SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI=$KC_URL
EOF
chmod 600 /opt/app/backend.env  # only owner can read
```

**systemd reads the env file:**
```ini
[Service]
User=appuser
EnvironmentFile=/opt/app/backend.env
ExecStart=/usr/bin/java -jar /opt/app/backend.jar
```

The chain: Terraform → SSM Parameter Store → EC2 user data → env file → systemd → JVM.
No secrets in git, no secrets in Terraform state (SSM values are marked sensitive),
no secrets visible in the AWS console (SecureString is encrypted at rest).

### How does the custom domain work? (The full chain)

**1. ACM certificate (`acm.tf`):**
```hcl
resource "aws_acm_certificate" "cdn" {
  provider    = aws.us_east_1  # MUST be us-east-1 for CloudFront
  domain_name = "spm.eggtive.com"
  validation_method = "DNS"
}
```

**2. DNS validation record (automatic):**
Terraform reads the validation options from ACM and creates a CNAME in Route 53:
```hcl
resource "aws_route53_record" "cert_validation" {
  for_each = { for dvo in aws_acm_certificate.cdn.domain_validation_options : ... }
  zone_id  = data.aws_route53_zone.domain.zone_id  # eggtive.com zone
  name     = each.value.name    # _abc123.spm.eggtive.com
  type     = "CNAME"
  records  = [each.value.record] # _xyz789.acm-validations.aws
}
```
AWS checks this CNAME exists → proves you own the domain → issues the cert.

**3. CloudFront uses the cert:**
```hcl
aliases = ["spm.eggtive.com"]
viewer_certificate {
  acm_certificate_arn      = aws_acm_certificate_validation.cdn.certificate_arn
  ssl_support_method       = "sni-only"
  minimum_protocol_version = "TLSv1.2_2021"
}
```

**4. DNS alias record:**
```hcl
resource "aws_route53_record" "cdn" {
  name = "spm.eggtive.com"
  type = "A"
  alias {
    name    = aws_cloudfront_distribution.main.domain_name  # d1234.cloudfront.net
    zone_id = aws_cloudfront_distribution.main.hosted_zone_id
  }
}
```

**The request flow:**
```
Browser: https://spm.eggtive.com
  → DNS: spm.eggtive.com → Route 53 alias → d1234.cloudfront.net
  → TLS: CloudFront presents ACM cert for spm.eggtive.com
  → CloudFront: routes based on path (/, /api/*, /auth/*)
```

### How does boot resilience work? (Self-healing EC2s)

EC2 userdata is split into two phases:
- **Phase 1 (userdata):** System setup — installs JDK, creates users, writes systemd units
  and setup scripts. Always succeeds, no external dependencies.
- **Phase 2 (systemd ExecStartPre):** Downloads artifacts from S3, reads SSM config.
  Retried automatically by systemd every 30 seconds until it succeeds.

This is necessary because of a chicken-and-egg problem: the S3 bucket is created
by Terraform, so we can't upload artifacts before `terraform apply`. But `terraform apply`
also creates the EC2s. So the EC2s boot before artifacts are in S3.

**The `make up` timeline:**
```
terraform apply (creates S3 buckets, EC2s, RDS, etc. in parallel)
  │
  ├── EC2 boots → userdata Phase 1 runs (JDK, systemd units)
  │   └── systemd starts service → ExecStartPre tries S3 download → fails (not uploaded yet)
  │       └── systemd waits 30s → retries → fails again → waits 30s → ...
  │
  ├── RDS finishes creating → Terraform writes SSM params
  │
  └── terraform apply completes
      │
      Makefile uploads artifacts to S3 (tarballs, realm exports)
      │
      └── next ExecStartPre retry → S3 download succeeds → service starts ✓
```

**Terraform `depends_on` reduces the race:**
EC2 resources have `depends_on` for RDS, SSM parameters, and VPC endpoints.
This ensures Terraform creates those resources before the EC2s, so SSM reads
in userdata succeed on first try. The self-healing retry is a safety net for
edge cases (VPC endpoint DNS propagation, transient errors).

**Backend self-healing (`ExecStartPre`):**
```bash
# Downloads JAR if not present
if [ ! -f /opt/app/backend.jar ]; then
  aws s3 cp "s3://.../spm-app.jar" /opt/app/backend.jar  # fails if not in S3 → systemd retries
fi

# Always refreshes config from SSM (ensures latest values)
DB_URL=$(aws ssm get-parameter --name ".../db/url" ...)
# writes /opt/app/backend.env
```

**Keycloak self-healing (`ExecStartPre`):**
```bash
# Downloads + extracts tarball if not present
if [ ! -f /opt/keycloak/bin/kc.sh ]; then
  aws s3 cp "s3://.../keycloak.tar.gz" /tmp/  # fails if not in S3 → systemd retries
  # extract, build, import realm
fi
```

**systemd config that enables retries:**
```ini
Restart=always          # restart on any failure
RestartSec=30           # wait 30s between retries
StartLimitIntervalSec=0 # never give up
```

**On subsequent `make up` runs (artifacts already in S3):**
EC2s boot → ExecStartPre downloads immediately → services start on first try.
No retries needed.

**Keycloak also creates the `keycloakdb` database** during userdata Phase 1:
```bash
PGPASSWORD="$KC_DB_PASSWORD" psql -h "$DB_HOST" -U "$KC_DB_USERNAME" -d postgres \
  -c "CREATE DATABASE keycloakdb"
```
This is idempotent — skips if the database already exists.

### How does Keycloak realm setup work?

Keycloak realm configuration (realm, clients, roles) is application-level config
stored in the RDS database, not in Terraform. It's handled via realm import at boot.

**Realm export files in S3:**
```
s3://eggtive-spm-artifacts/keycloak/
├── realm-export.json           ← realm, clients, roles (used by dev + prod)
└── realm-export-dev-users.json ← test users with known passwords (dev only)
```

These files live in `infra/exports/` in git and are uploaded to S3 by `make up`.

**How import works (inside the ExecStartPre setup script):**
The import runs once — when the Keycloak tarball is first downloaded and extracted.
On subsequent boots (tarball already exists), the setup script skips download and import.

```bash
# Only runs on first setup (tarball not yet extracted)
if [ ! -f /opt/keycloak/bin/kc.sh ]; then
  # download tarball, extract, build
  # then import realm:
  aws s3 cp "s3://.../realm-export.json" /tmp/kc-import/
  if [ "$ENVIRONMENT" = "dev" ]; then
    aws s3 cp "s3://.../realm-export-dev-users.json" /tmp/kc-import/
  fi
  kc.sh import --dir /tmp/kc-import --override false
fi
```

The `--override false` flag is critical — it means:
- Fresh DB (first `make up`): realm is created from the export files
- Existing DB (snapshot restore, or `make down`/`make up` cycle): import is skipped,
  existing realm data is preserved (including any users created via admin console)

**Dev vs Prod:**
- Dev: imports realm + roles + test users. Developers can also create users via admin console.
- Prod: imports realm + roles only. Admin creates real users via the admin console.
  The `environment` variable controls this — Terraform passes it to the userdata template.

**How to update realm config:**
1. Make changes in the Keycloak admin console (dev)
2. Export the realm: Realm Settings → Action → Partial Export
3. Save to `infra/exports/realm-export.json` and commit to git
4. Next fresh `make up` (with new DB) will use the updated export

**How to force re-import (e.g., after updating the export):**
```bash
terraform taint 'aws_instance.keycloak[0]'
make up
```
This recreates the Keycloak EC2 with fresh userdata. If the DB still has the old
realm, `--override false` will skip the import. To truly re-import, you'd need to
delete the realm first or use `--override true` (destructive — overwrites existing data).

### How does Keycloak hostname work behind CloudFront?

Keycloak needs to generate correct URLs (with `https://` scheme and the right domain)
for OAuth redirects, token endpoints, and the admin console. The challenge:
CloudFront terminates TLS and forwards HTTP to the ALB, which forwards HTTP to Keycloak.

The solution is `hostname=https://spm.eggtive.com/auth` + `http-enabled=true` in `keycloak.conf`:
```
hostname=https://${custom_domain}/auth
http-enabled=true
```

This is Keycloak 26's "edge TLS termination" mode (documented at keycloak.org/server/hostname).
The `hostname` with `https://` scheme tells Keycloak to generate all URLs with HTTPS,
while `http-enabled=true` allows the server to accept HTTP connections from the ALB.

IMPORTANT GOTCHAS (do not change these):
- `hostname=https://...` requires `http-enabled=true` — without it, Keycloak demands TLS certs
  and fails with "Key material not provided to setup HTTPS"
- `proxy-headers=xforwarded` does NOT work for this setup — the ALB overwrites
  `X-Forwarded-Proto` with `http` (based on its listener protocol), so Keycloak
  always sees HTTP and generates `http://` URLs causing mixed-content errors
- The config file is saved to `/opt/deploy/keycloak.conf` (staging) and copied
  into `/opt/keycloak/conf/keycloak.conf` by the setup script AFTER tarball
  extraction — because the tarball overwrites the default config file

---

## How Is It Secured? (Specific controls)

| Layer | Threat | Control | Implementation |
|-------|--------|---------|----------------|
| Network | Direct access to backend | No public subnets, IGW has no routes | `vpc.tf`: IGW exists (required by VPC origins) but no route table references it |
| Network | Traffic sniffing | AWS backbone only | `vpc_endpoints.tf`: all AWS API calls via VPC endpoints |
| Ingress | Bypass CloudFront | ALB only accepts CloudFront | `security_groups.tf`: ALB SG ingress from CloudFront managed prefix list |
| Ingress | Direct EC2 access | EC2 only accepts ALB | `security_groups.tf`: backend SG ingress from ALB SG on port 8080 only |
| Database | Unauthorized DB access | RDS only accepts app servers | `security_groups.tf`: RDS SG ingress from backend SG + keycloak SG on port 5432 |
| Instance | SSH brute force | No SSH at all | No port 22 in any security group. SSM Session Manager via VPC endpoints |
| Secrets | Credential exposure | No hardcoded secrets | `rds.tf`: `random_password` → SSM SecureString. EC2 reads at boot via IAM role |
| CI/CD | Stolen AWS keys | No long-lived keys | `iam.tf`: GitHub OIDC federation. Trust policy scoped to `repo:mintun-myo-2020/spm:*` |
| S3 | Public bucket exposure | All public access blocked | `s3.tf`: `block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets` all true |
| S3 | Direct S3 URL access | OAC restricts to CloudFront | `cloudfront.tf`: bucket policy allows `s3:GetObject` only when `AWS:SourceArn` matches CloudFront distribution ARN |
| TLS | Downgrade attacks | Modern TLS only | `cloudfront.tf`: `minimum_protocol_version = "TLSv1.2_2021"`, `viewer_protocol_policy = "redirect-to-https"` |
| IAM | Over-privileged roles | Least privilege | EC2 role: read-only on specific S3 bucket + specific SSM path. GitHub role: scoped to specific buckets + SSM commands |

---

## What Does It Cost?

| Resource | Always on? | Config | Monthly |
|----------|-----------|--------|---------|
| VPC + subnets | Yes | 10.0.0.0/16, 2 private subnets | Free |
| S3 gateway endpoint | Yes | Gateway type | Free |
| S3 frontend bucket | Yes | Versioned, private | < $0.10 |
| S3 artifacts bucket | Yes | Versioned, private | < $0.10 |
| CloudFront | Yes | PriceClass_All, custom domain | Free tier (1TB/mo) |
| ACM certificate | Yes | spm.eggtive.com | Free |
| Route 53 public zone | Yes | eggtive.com (pre-existing) | $0.50 |
| Route 53 private zone | Yes | internal.dev.eggtive-spm | $0.50 |
| IAM roles + policies | Yes | EC2 role, GitHub OIDC role | Free |
| SSM parameters (2) | Yes | keycloak admin pw, keycloak url | Free |
| **Always-on total** | | | **~$1-2** |
| EC2 backend | On-demand | t3.small, 30GB gp3 | ~$15 |
| EC2 keycloak | On-demand | t3.small, 30GB gp3 | ~$15 |
| RDS PostgreSQL | On-demand | db.t3.micro, 20GB gp3, single-AZ | ~$13 |
| ALB | On-demand | Internal, 2 target groups | ~$16 |
| VPC interface endpoints | On-demand | ×5 (SSM, SSMMsg, EC2Msg, CW Logs, Bedrock) | ~$36 |
| SSM parameters (6) | On-demand | DB creds, keycloak DB creds | Free |
| **On-demand total** | | | **~$95-100** |

| Scenario | Monthly |
|----------|---------|
| `make down` (env off) | ~$1-2 |
| 8 hrs/day weekdays (~23% uptime) | ~$24-27 |
| 24/7 | ~$97-102 |

---

## Known Issues & Workarounds

### CloudFront VPC Origin deletion fails on `make down` or `terraform destroy`

**Symptom:** `CannotDeleteEntityWhileInUse: The specified VPC origin is currently associated with one or more distributions`

**Cause:** Terraform tries to delete the VPC origin before CloudFront finishes disassociating it from the distribution. CloudFront distribution updates are async — Terraform marks it done but CloudFront hasn't actually deployed the change yet. This is a known limitation of the AWS Terraform provider.

**Workaround (manual, takes ~5 minutes):**
1. Go to AWS Console → CloudFront → Distributions
2. Select your distribution → General tab → Edit → set "Enabled" to **No** → Save
3. Wait for status to change to "Deployed" (2-5 minutes)
4. Delete the distribution
5. Go to CloudFront → VPC origins → delete the orphaned VPC origin
6. Run `terraform state rm 'aws_cloudfront_vpc_origin.alb[0]'` to clean up state
7. Run `make down` or `terraform destroy` again — it will succeed

**When this happens:**
- Every `make down` (switching `env_active` from true to false)
- Every `terraform destroy`
- Any time the ALB is being replaced (which triggers VPC origin replacement)

**Does NOT happen on:**
- `make up` (creating resources)
- Tainting EC2s only (VPC origin stays)
