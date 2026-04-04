# Resource-Level Architecture Reference — Eggtive SPM

Every AWS resource, its exact configuration, and why it's configured that way.

Resources are grouped by lifecycle:
- **Always on** — exists regardless of `env_active`, costs ~$1-2/mo
- **On-demand** — only exists when `env_active = true`, costs ~$88-93/mo

---

## Always-On Resources

### VPC (`vpc.tf`)

**`aws_vpc.main`**
- CIDR: `10.0.0.0/16` (65,536 IPs — plenty of room)
- `enable_dns_support = true` — required for VPC endpoints and Route 53 private zones
- `enable_dns_hostnames = true` — required for RDS to get a DNS name
- Why /16: gives room for future subnets (public, additional AZs) without re-architecting

**`aws_subnet.private` (×2)**
- `10.0.1.0/24` in `ap-southeast-1a` (254 usable IPs)
- `10.0.2.0/24` in `ap-southeast-1b` (254 usable IPs)
- Two AZs required by ALB and RDS subnet group (AWS mandates multi-AZ subnet groups)
- No `map_public_ip_on_launch` — these are private, no public IPs ever assigned
- Why two subnets: ALB requires subnets in at least 2 AZs. RDS subnet group requires the same.

**`aws_route_table.private`**
- No routes to the internet gateway or NAT gateway
- Only route is the local VPC route (implicit) and S3 gateway endpoint
- This is what makes the subnets truly private — there is no path to the internet
- The IGW exists but no route table references it

**`aws_internet_gateway.main`**
- Attached to the VPC but not referenced in any route table
- Required by CloudFront VPC origins (AWS mandates an IGW exists on the VPC)
- Does not enable any internet access — no routes point to it, no public subnets exist
- Free resource, no security impact

### S3 Gateway VPC Endpoint (`vpc_endpoints.tf`)

**`aws_vpc_endpoint.s3`**
- Type: `Gateway` (free, no hourly charge)
- Attached to the private route table
- Why: EC2 instances need to pull artifacts from S3 and AL2023 package repos are hosted on S3. Without this, `dnf install` and `aws s3 cp` would fail since there's no internet access.
- Why gateway not interface: S3 gateway endpoints are free. Interface endpoints cost $7.20/mo.

### VPC Endpoint Security Group (`security_groups.tf`)

**`aws_security_group.vpc_endpoints`**
- Ingress: TCP 443 from `10.0.0.0/16` (entire VPC)
- Egress: all traffic
- Why port 443: all AWS API calls (SSM, CloudWatch, etc.) use HTTPS
- Why always on: the security group must exist before interface endpoints reference it. Costs nothing.
- `create_before_destroy = true` — prevents downtime if Terraform needs to replace it

### S3 Buckets (`s3.tf`)

**`aws_s3_bucket.frontend`** — `eggtive-spm-dev-frontend`
- Stores React build output (index.html, static/js, static/css)
- Versioning: enabled (rollback capability)
- Public access: all blocked (4 block settings)
- Accessed only via CloudFront OAC — no direct access possible
- Contains maintenance JSON files at `api/maintenance.json` and `auth/maintenance.json` served when env is down
- Why versioning: if a bad frontend deploy goes out, you can restore the previous version from S3 version history

**`aws_s3_bucket.artifacts`** — `eggtive-spm-artifacts`
- Stores build artifacts: `spm-app.jar`, `keycloak/keycloak.tar.gz`
- Versioning: enabled
- Public access: all blocked
- EC2 instances pull from here via S3 gateway endpoint (free, on backbone)
- CI pushes here via GitHub Actions OIDC role

### CloudFront (`cloudfront.tf`)

**`aws_cloudfront_origin_access_control.s3`**
- Signing: SigV4, always
- Why OAC over OAI: OAC is the newer, recommended approach. Supports SSE-KMS and more granular policies.

**`aws_s3_bucket_policy.frontend`**
- Allows `s3:GetObject` only from this specific CloudFront distribution (matched by ARN)
- Even if someone guesses the bucket name, they can't read objects without going through CloudFront

**`aws_cloudfront_distribution.main`**
- `enabled = true`, `default_root_object = "index.html"`
- `price_class = "PriceClass_100"` — cheapest tier, US/Canada/Europe edges only. Why: dev environment, no need for global edge coverage. Saves ~30% on CloudFront costs.
- `aliases = ["spm.eggtive.com"]` — custom domain
- `comment = "eggtive-spm-dev"` — used by CI to find the distribution ID for cache invalidation

**Origins:**
- `s3-frontend` (always present) — serves React SPA and maintenance pages
- `alb-backend` (dynamic, only when `env_active = true`) — connects to internal ALB via CloudFront VPC origin
  - Uses `aws_cloudfront_vpc_origin` which creates a managed ENI inside the VPC
  - `origin_protocol_policy = "http-only"` — CloudFront talks to ALB over HTTP port 80 (internal traffic, no TLS needed)
  - `depends_on = [aws_internet_gateway.main]` — VPC origin requires IGW to exist before creation
  - Why VPC origin: CloudFront cannot reach internal ALBs via regular `custom_origin_config` (it can't resolve private IPs). VPC origins create an ENI inside the VPC for direct connectivity.

**Cache behaviors:**
- `/*` (default) → S3. Cached for 24hrs. Static assets rarely change between deploys.
- `/api/*` → ALB when active, S3 maintenance when down. TTL=0 (no caching). Forwards query strings, Authorization header, cookies. Why no cache: API responses are dynamic and user-specific.
- `/auth/*` → ALB when active, S3 maintenance when down. TTL=0. Same forwarding. Why: Keycloak auth flows use cookies and query params that must pass through.

**SPA fallback:**
- 403 → 200 `/index.html` — S3 returns 403 for paths that don't exist as files. React Router needs all paths to serve index.html.
- 404 → 200 `/index.html` — same reason.

**TLS:**
- ACM certificate ARN from `aws_acm_certificate_validation.cdn`
- `ssl_support_method = "sni-only"` — no dedicated IP ($600/mo savings)
- `minimum_protocol_version = "TLSv1.2_2021"` — modern TLS only, no legacy browser support

### ACM Certificate (`acm.tf`)

**`provider "aws" alias "us_east_1"`**
- Separate provider in us-east-1
- Why: CloudFront requires ACM certificates to be in us-east-1, regardless of where your other resources live (ap-southeast-1)

**`aws_acm_certificate.cdn`**
- Domain: `spm.eggtive.com`
- Validation: DNS (automated via Route 53)
- `create_before_destroy = true` — if cert needs replacement, new one is created and validated before old one is deleted. Prevents downtime.

**`aws_route53_record.cert_validation`**
- Auto-creates the CNAME validation record in the eggtive.com hosted zone
- AWS checks this record to prove you own the domain
- Validation typically completes in 2-5 minutes

**`aws_route53_record.cdn`**
- Type: A record (alias) pointing `spm.eggtive.com` → CloudFront distribution
- Why alias over CNAME: alias records are free in Route 53 and work at the zone apex. CNAMEs cost per query.

### Route 53 Public Zone (`acm.tf`)

**`data.aws_route53_zone.domain`**
- Looks up the existing `eggtive.com` hosted zone (created when you bought the domain)
- Not managed by Terraform — just referenced
- Used for: ACM validation records, CloudFront alias record

### Route 53 Private Hosted Zone (`dns.tf`)

**`aws_route53_zone.internal`**
- Zone: `internal.dev.eggtive-spm`
- Associated with the VPC — only resolvable from within the VPC
- Always on (costs $0.50/mo)
- Why: services reference each other by DNS name, not IP. When instances are replaced, Terraform updates the records. App config never changes.
- A/CNAME records are on-demand (only exist when `env_active = true`)

### IAM — EC2 Role (`iam.tf`)

**`aws_iam_role.ec2`** + **`aws_iam_instance_profile.ec2`**
- Assumed by: EC2 instances (both backend and keycloak share this role)
- Always on (IAM is free)

**Attached policies:**
- `AmazonSSMManagedInstanceCore` (AWS managed) — allows SSM Session Manager. Why managed policy: it's maintained by AWS and covers all SSM agent requirements.
- `ec2_s3_read` — `s3:GetObject`, `s3:ListBucket` on artifacts bucket only. Why: EC2 needs to download JARs. Read-only, scoped to one bucket.
- `ec2_ssm_params` — `ssm:GetParameter*` on `/eggtive-spm/dev/*` only. Why: EC2 pulls DB credentials and Keycloak config at boot. Scoped to this environment's parameter path.
- `ec2_cloudwatch` — `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`. Why: for future CloudWatch agent logging. Currently permissions exist but agent isn't installed yet.

### IAM — GitHub Actions OIDC (`iam.tf`)

**`aws_iam_openid_connect_provider.github`**
- URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`
- Why: allows GitHub Actions to assume an IAM role without storing AWS access keys. Short-lived tokens only.

**`aws_iam_role.github_actions`** — `eggtive-spm-dev-github-actions`
- Trust policy: federated identity from GitHub OIDC provider
- Condition: `repo:mintun-myo-2020/spm:*` — only this specific repo can assume the role
- Why StringLike with `:*`: allows any branch, tag, or environment to assume the role. Could be tightened to `:ref:refs/heads/main` for main-only.

**Attached policies:**
- `github_s3` — read/write/delete on frontend bucket + artifacts bucket. Why: CI pushes frontend builds and backend JARs.
- `github_cloudfront` — `CreateInvalidation`, `ListDistributions` on `*`. Why: CI invalidates CloudFront cache after frontend deploy. `ListDistributions` needed to find the distribution by comment.
- `github_ssm_deploy` — `SendCommand`, `GetCommandInvocation` on EC2 instances. Why: CI triggers deploy.sh on EC2 after uploading new JAR.
- `github_terraform` — read/write on state bucket + DynamoDB lock table. Why: infra pipeline needs to read/write Terraform state.

### SSM Parameter Store (`ssm.tf` + `rds.tf`)

**Always-on parameters:**
- `/eggtive-spm/dev/keycloak/admin/password` — SecureString, auto-generated (24 chars, no special)
- `/eggtive-spm/dev/keycloak/url` — String, `http://keycloak.internal.dev.eggtive-spm:8443/auth/realms/master`

**On-demand parameters (only when env_active):**
- `/eggtive-spm/dev/db/url` — SecureString, `jdbc:postgresql://<rds-endpoint>:5432/appdb`
- `/eggtive-spm/dev/db/username` — SecureString, `dbadmin`
- `/eggtive-spm/dev/db/password` — SecureString, auto-generated (32 chars, no special)
- `/eggtive-spm/dev/keycloak/db/url` — SecureString, `jdbc:postgresql://<rds-endpoint>:5432/keycloakdb`
- `/eggtive-spm/dev/keycloak/db/username` — SecureString, `dbadmin`
- `/eggtive-spm/dev/keycloak/db/password` — SecureString, same as db/password (shared RDS instance)

Why on-demand: the DB URL contains the RDS endpoint which doesn't exist when env is down. Terraform creates these parameters alongside the RDS instance.

### Terraform State (`main.tf` + bootstrapped manually)

**S3 Backend:**
- Bucket: `eggtive-spm-terraform-state`
- Key: `dev/terraform.tfstate`
- Region: `ap-southeast-1`
- Encryption: enabled
- Versioning: enabled (on the bucket)
- Why S3: standard Terraform remote state. Versioning means you can recover from a corrupted state file.

**DynamoDB Lock Table:**
- Table: `terraform-locks`
- Key: `LockID` (String)
- Billing: pay-per-request
- Why: prevents two `terraform apply` runs from executing simultaneously and corrupting state.

---

## On-Demand Resources (env_active = true)

### CloudFront VPC Origin (`cloudfront.tf`)

**`aws_cloudfront_vpc_origin.alb`**
- Creates a managed ENI inside the VPC for CloudFront to reach the internal ALB
- `origin_protocol_policy = "http-only"` — HTTP on port 80
- `depends_on = [aws_internet_gateway.main]` — IGW must exist before VPC origin creation
- Cost: no additional charge (included with CloudFront)
- Why on-demand: only needed when the ALB exists (`env_active = true`)

### VPC Interface Endpoints (`vpc_endpoints.tf`)

**`aws_vpc_endpoint.interface` (×4)**
- `ssm` — SSM API calls (Session Manager, parameter store)
- `ssmmessages` — SSM Session Manager WebSocket connections
- `ec2messages` — SSM agent polling for commands
- `logs` — CloudWatch Logs API

All configured with:
- Type: Interface
- `private_dns_enabled = true` — so `ssm.ap-southeast-1.amazonaws.com` resolves to the endpoint's private IP, not the public IP
- Subnets: both private subnets
- SG: vpc_endpoints security group (port 443 from VPC CIDR)
- Cost: $7.20/mo each = $28.80/mo total

Why on-demand: these are only needed when EC2 instances are running. No point paying $29/mo when the env is down.

### ALB (`alb.tf`)

**`aws_lb.main`**
- `internal = true` — no public IP, not internet-facing
- `load_balancer_type = "application"` — layer 7, supports path-based routing
- Subnets: both private subnets (ALB requires 2 AZs minimum)
- SG: ALB security group
- Why internal: CloudFront connects to it. Nothing else should.

**`aws_security_group.alb`**
- Ingress: TCP 80 from CloudFront managed prefix list (`com.amazonaws.global.cloudfront.origin-facing`)
- Why prefix list: AWS maintains this list with all CloudFront IPs. Works with both VPC origins and regular origins. CloudFront VPC origin ENI traffic is tagged with these IPs.
- Why port 80: CloudFront connects with `origin_protocol_policy = "http-only"`. Internal traffic, no TLS needed.

**`aws_lb_listener.http`**
- Port 80, HTTP
- Default action: 404 JSON response
- Why 404 default: only `/api/*` and `/auth/*` should be routed. Anything else is a misconfiguration.

**`aws_lb_target_group.backend`**
- Port: 8080, HTTP
- Health check: `GET /actuator/health` on port 8080
  - Healthy threshold: 2 consecutive successes
  - Unhealthy threshold: 3 consecutive failures
  - Interval: 30 seconds
- Why `/actuator/health`: Spring Boot standard health endpoint

**`aws_lb_listener_rule.backend`**
- Priority: 100
- Condition: path pattern `/api/*`
- Action: forward to backend target group

**`aws_lb_target_group.keycloak`**
- Port: 8443, HTTP
- Health check: `GET /auth/health/ready` on port 9000 (management interface)
- Why port 9000: Keycloak 26.x serves health and metrics on a separate management port (9000), not the main HTTP port
- Why `/auth/health/ready`: `http-relative-path=/auth` is inherited by the management interface

**`aws_lb_listener_rule.keycloak`**
- Priority: 200 (lower priority than backend)
- Condition: path pattern `/auth/*`
- Action: forward to keycloak target group

### EC2 — Backend (`ec2_backend.tf`)

**`aws_instance.backend`**
- AMI: Amazon Linux 2023 (latest, x86_64, HVM)
- Instance type: `t3.small` (2 vCPU, 2 GB RAM)
- Subnet: private subnet A (ap-southeast-1a)
- SG: backend security group (ingress: ALB→8080 only)
- IAM profile: shared EC2 profile (SSM + S3 + SSM params + CloudWatch)
- Root volume: 30 GB gp3, encrypted
- Tags: `Service=backend`, `Environment=dev` — used by SSM send-command to target this instance

Why t3.small: 2 GB RAM is minimum for a Spring Boot app. t3.micro (1 GB) would likely OOM.
Why gp3: baseline 3000 IOPS, no burst credits to worry about. Cheaper than gp2 for this size.
Why encrypted: EBS encryption at rest, uses default AWS KMS key. No performance impact.

**User data (`templates/backend_userdata.sh`):**
1. Installs Amazon Corretto JDK 21 (headless)
2. Creates `appuser` system user (no shell, no login)
3. Downloads `spm-app.jar` from S3 (non-fatal if missing)
4. Pulls DB credentials and Keycloak URL from SSM Parameter Store
5. Writes `/opt/app/backend.env` (environment file for systemd)
6. Creates `/etc/systemd/system/backend.service` (systemd unit)
7. Creates `/opt/deploy/deploy.sh` (deploy script for CI)
8. Starts the service if JAR was downloaded

### EC2 — Keycloak (`ec2_keycloak.tf`)

**`aws_instance.keycloak`**
- Same base config as backend (AMI, instance type, subnet, IAM profile, volume)
- SG: keycloak security group (ingress: ALB→8443 only)
- Tags: `Service=keycloak`, `Environment=dev`

**User data (`templates/keycloak_userdata.sh`):**
1. Installs Amazon Corretto JDK 21
2. Creates `keycloak` system user
3. Downloads and extracts Keycloak tarball from S3 (non-fatal if missing)
4. Pulls DB credentials and admin password from SSM
5. Writes `/opt/keycloak/conf/keycloak.conf` (Keycloak config)
6. Creates systemd unit with admin password override from SSM
7. Starts if tarball was downloaded

Keycloak config specifics:
- `db=postgres` — uses PostgreSQL backend
- `hostname=https://<custom_domain>/auth` — edge TLS termination mode. Forces HTTPS URLs in all OAuth responses. Uses `var.custom_domain` from Terraform.
- `http-enabled=true` — REQUIRED with `hostname=https://...`, allows HTTP connections from ALB. Without this, Keycloak demands TLS certs and crashes.
- `http-port=8443` — HTTP listen port (non-standard, avoids conflict with backend's 8080)
- `http-relative-path=/auth` — serves all endpoints under `/auth/*` to match ALB path pattern and SSM URL
- `health-enabled=true` — enables health endpoints on the management port (9000)
- `metrics-enabled=true` — enables Prometheus metrics on the management port (9000)
- Do NOT use `proxy-headers=xforwarded` — the ALB overwrites `X-Forwarded-Proto` to `http`, causing mixed-content errors
- Config is saved to `/opt/deploy/keycloak.conf` (staging) and copied after tarball extraction to avoid being overwritten

The management interface (health + metrics) runs on port 9000 by default in Keycloak 26.x.
The `http-relative-path=/auth` is inherited, so health is at `:9000/auth/health/ready` and metrics at `:9000/auth/metrics`.
Both `health-enabled` and `metrics-enabled` must be in `keycloak.conf` so `kc.sh build` compiles them into the runtime.

**Realm import at boot:**
After `kc.sh build`, the userdata imports realm config from S3:
- `realm-export.json` — realm, clients, roles (both dev and prod)
- `realm-export-dev-users.json` — test users (dev only, controlled by `environment` template variable)
- Uses `--override false` so existing realm data is never overwritten

### EC2 Security Groups (`security_groups.tf`)

**`aws_security_group.backend`**
- Ingress: TCP 8080 from ALB security group only
- Egress: all (needed for S3, SSM, CloudWatch via VPC endpoints)
- Why SG-to-SG reference: more secure than CIDR. If ALB's IP changes, the rule still works.

**`aws_security_group.keycloak`**
- Ingress: TCP 8443 from ALB security group (app traffic) + Prometheus SG
- Ingress: TCP 9000 from ALB security group (health checks) + Prometheus SG (metrics scraping)
- Same egress pattern
- Why port 9000 from ALB: Keycloak 26.x health checks are on the management port, and the ALB health check targets port 9000

Note: neither EC2 has port 22 open. No SSH access at all. SSM Session Manager doesn't need any inbound ports.

### RDS (`rds.tf`)

**`aws_db_instance.main`**
- Engine: PostgreSQL 16
- Instance class: `db.t3.micro` (2 vCPU, 1 GB RAM)
- Storage: 20 GB gp3, auto-scaling up to 50 GB, encrypted
- Database name: `appdb` (Keycloak uses a separate database `keycloakdb` on the same instance)
- Username: `dbadmin`, password: auto-generated (32 chars)
- `multi_az = false` — single AZ for dev (saves ~$13/mo)
- `publicly_accessible = false` — no public endpoint
- `skip_final_snapshot = false` — always takes a snapshot on destroy

Why single instance with 2 databases: Keycloak and the app both need Postgres. Running two RDS instances would double the cost. Two databases on one instance is fine for dev.
Why db.t3.micro: cheapest RDS instance. 1 GB RAM is enough for dev workloads.
Why final snapshot: when you `make down`, the RDS is destroyed but a snapshot is kept. Data isn't lost.

**`aws_security_group.rds`**
- Ingress: TCP 5432 from backend SG + TCP 5432 from keycloak SG
- Only these two EC2 instances can connect. Nothing else.

### Route 53 Private Records (`dns.tf`)

**`aws_route53_record.backend`**
- `backend.internal.dev.eggtive-spm` → backend EC2 private IP
- Type: A, TTL: 60s

**`aws_route53_record.keycloak`**
- `keycloak.internal.dev.eggtive-spm` → keycloak EC2 private IP
- Type: A, TTL: 60s

**`aws_route53_record.db`**
- `db.internal.dev.eggtive-spm` → RDS endpoint
- Type: CNAME, TTL: 60s
- Why CNAME: RDS endpoints are DNS names, not IPs. Can't use an A record.

Why 60s TTL: when instances are replaced, DNS updates quickly. 60s is a good balance between freshness and query volume.
