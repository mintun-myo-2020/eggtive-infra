# Infrastructure Plan — Full-Stack App on AWS

## 1. Overview

Deploy a full-stack application (React frontend + backend + Keycloak) on AWS with:
- Minimal footprint (single EC2, single RDS)
- Zero public exposure except through CloudFront
- All internal traffic on AWS backbone (VPC endpoints, no NAT gateway)
- Infrastructure as Code via Terraform
- CI/CD pipeline for automated builds and deploys
- On-demand environment: expensive resources (EC2, RDS, ALB) spin up/down with a single command

---

## 2. Architecture

### 2.1 Network Topology

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              AWS Account                                │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                        VPC (10.0.0.0/16)                          │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────┐  ┌─────────────────────────────┐ │  │
│  │  │   Private Subnet A (AZ-a)   │  │   Private Subnet B (AZ-b)   │ │  │
│  │  │        10.0.1.0/24          │  │        10.0.2.0/24          │ │  │
│  │  │                             │  │                             │ │  │
│  │  │  ┌───────────────────────┐  │  │  ┌───────────────────────┐  │ │  │
│  │  │  │        ALB            │◄─┼──┼──┤        ALB            │  │ │  │
│  │  │  │  (internal, multi-AZ) │  │  │  │   (target in AZ-b)    │  │ │  │
│  │  │  └───────────┬───────────┘  │  │  └───────────────────────┘  │ │  │
│  │  │              │              │  │                             │ │  │
│  │  │  ┌───────────▼───────────┐  │  │                             │ │  │
│  │  │  │       EC2 (t3.small)  │  │  │                             │ │  │
│  │  │  │  ┌─────────────────┐  │  │  │                             │ │  │
│  │  │  │  │  docker-compose │  │  │  │                             │ │  │
│  │  │  │  │  ┌───────────┐  │  │  │  │                             │ │  │
│  │  │  │  │  │  Backend   │  │  │  │  │                             │ │  │
│  │  │  │  │  │  :8080     │  │  │  │  │                             │ │  │
│  │  │  │  │  ├───────────┤  │  │  │  │                             │ │  │
│  │  │  │  │  │ Keycloak  │  │  │  │  │                             │ │  │
│  │  │  │  │  │  :8443    │  │  │  │  │                             │ │  │
│  │  │  │  │  └───────────┘  │  │  │  │                             │ │  │
│  │  │  │  └─────────────────┘  │  │  │                             │ │  │
│  │  │  └───────────────────────┘  │  │                             │ │  │
│  │  │                             │  │                             │ │  │
│  │  │  ┌───────────────────────┐  │  │  ┌───────────────────────┐  │ │  │
│  │  │  │   RDS Postgres        │  │  │  │   RDS Postgres        │  │ │  │
│  │  │  │   (primary, AZ-a)     │  │  │  │   (standby if multi-  │  │ │  │
│  │  │  │   - app_db            │  │  │  │    AZ, else unused)   │  │ │  │
│  │  │  │   - keycloak_db       │  │  │  │                       │  │ │  │
│  │  │  └───────────────────────┘  │  │  └───────────────────────┘  │ │  │
│  │  │                             │  │                             │ │  │
│  │  └─────────────────────────────┘  └─────────────────────────────┘ │  │
│  │                                                                   │  │
│  │  ┌─────────────────────────────────────────────────────────────┐  │  │
│  │  │                    VPC Endpoints                             │  │  │
│  │  │  - S3 (gateway)                                             │  │  │
│  │  │  - SSM, SSM Messages, EC2 Messages (interface, for access)  │  │  │
│  │  │  - ECR API + ECR DKR (interface, for docker pull)           │  │  │
│  │  │  - CloudWatch Logs (interface, for logging)                 │  │  │
│  │  └─────────────────────────────────────────────────────────────┘  │  │
│  │                                                                   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌──────────────────────┐     ┌──────────────────────┐                  │
│  │   S3 Bucket           │     │   ECR Repository      │                 │
│  │   (React build assets)│     │   (backend + keycloak  │                 │
│  │   - index.html        │     │    docker images)      │                 │
│  │   - static/           │     │                        │                 │
│  └──────────┬────────────┘     └────────────────────────┘                │
│             │                                                            │
└─────────────┼────────────────────────────────────────────────────────────┘
              │
```

### 2.2 Request Flow (User → App)

```
    User's Browser
         │
         │  HTTPS (*.cloudfront.net or custom domain)
         ▼
  ┌──────────────┐
  │  CloudFront   │
  │  Distribution │
  └──────┬───────┘
         │
    ┌────┴─────────────────────┐
    │                          │
    │ Behavior: /*             │ Behavior: /api/*
    │ (default)                │ /auth/*
    │                          │
    ▼                          ▼
  ┌──────────┐          ┌──────────────┐
  │ S3 Origin │          │ ALB Origin    │
  │ (OAC)     │          │ (HTTPS, priv) │
  │           │          │               │
  │ React SPA │          │ ┌───────────┐ │
  │ assets    │          │ │ /api/* ──► │─┼──► EC2:8080 (backend)
  └──────────┘          │ │ /auth/* ─► │─┼──► EC2:8443 (keycloak)
                         │ └───────────┘ │
                         └──────────────┘
```

Key points:
- CloudFront is the ONLY public entry point
- ALB security group allows inbound ONLY from CloudFront managed prefix list
- EC2 security group allows inbound ONLY from ALB security group
- RDS security group allows inbound ONLY from EC2 security group
- S3 bucket is private, accessed via OAC (Origin Access Control)
- React SPA loads in browser, then calls `/api/*` which CloudFront proxies to ALB → EC2

### 2.3 Access & Management

```
  Developer laptop
       │
       │  AWS SSM Session Manager (no SSH, no bastion)
       │  (through AWS API, not through VPC)
       ▼
  ┌──────────┐
  │   EC2     │  ← IAM instance profile with SSM permissions
  └──────────┘
```

No SSH keys, no port 22, no bastion host. SSM goes through the interface VPC endpoints.

---

## 3. CI/CD Pipeline

### 3.1 Pipeline Architecture

```
  ┌──────────────┐
  │  GitHub Repo  │
  │  (mono-repo)  │
  │  ├── frontend/│
  │  ├── backend/ │
  │  ├── infra/   │
  │  └── deploy/  │
  └──────┬───────┘
         │
         │  push to main (or merge PR)
         ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                    GitHub Actions                             │
  │                                                              │
  │  ┌─────────────────────────────────────────────────────────┐ │
  │  │  Job: detect-changes                                    │ │
  │  │  - Determine which paths changed (frontend/backend/infra)│ │
  │  └────────┬──────────────┬──────────────┬──────────────────┘ │
  │           │              │              │                     │
  │     ┌─────▼─────┐ ┌─────▼─────┐ ┌─────▼──────┐             │
  │     │ Frontend   │ │ Backend   │ │ Infra      │             │
  │     │ Pipeline   │ │ Pipeline  │ │ Pipeline   │             │
  │     │            │ │           │ │            │             │
  │     │ npm ci     │ │ build     │ │ terraform  │             │
  │     │ npm test   │ │ test      │ │ plan       │             │
  │     │ npm build  │ │ docker    │ │ (manual    │             │
  │     │            │ │ build     │ │  approve)  │             │
  │     │ sync → S3  │ │ push →ECR │ │ terraform  │             │
  │     │            │ │           │ │ apply      │             │
  │     │ invalidate │ │ deploy to │ │            │             │
  │     │ CloudFront │ │ EC2 (SSM) │ │            │             │
  │     └────────────┘ └───────────┘ └────────────┘             │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
```

### 3.2 Pipeline Details

**Frontend pipeline** (triggered when `frontend/` changes):
1. Install deps, run tests, build
2. `aws s3 sync` build output to S3 bucket
3. Create CloudFront invalidation for `/*`

**Backend pipeline** (triggered when `backend/` changes):
1. Build and test
2. `docker build` → tag with git SHA
3. `docker push` to ECR
4. SSM Run Command on EC2: pull new image, `docker-compose up -d`

**Infra pipeline** (triggered when `infra/` changes):
1. `terraform fmt -check`
2. `terraform plan` → output as PR comment
3. Manual approval gate
4. `terraform apply`

### 3.3 GitHub Actions → AWS Auth

```
  GitHub Actions
       │
       │  OIDC federation (no long-lived keys)
       ▼
  ┌──────────────────┐
  │ IAM Role          │
  │ (trust: GitHub    │
  │  OIDC provider)   │
  │                   │
  │ Permissions:      │
  │ - S3 (frontend)   │
  │ - ECR (push)      │
  │ - SSM (deploy)    │
  │ - CloudFront      │
  │   (invalidation)  │
  │ - Terraform state │
  │   (S3 + DynamoDB) │
  └──────────────────┘
```

No AWS access keys stored in GitHub secrets. OIDC federation only.

---

## 4. Terraform Structure

```
infra/
├── main.tf                 # provider config, terraform backend (S3 + DynamoDB)
├── variables.tf            # input variables (incl. env_active, environment)
├── outputs.tf              # useful outputs (CloudFront URL, ALB DNS, etc.)
├── vpc.tf                  # VPC, subnets (private only), route tables
├── vpc_endpoints.tf        # S3 gateway + interface endpoints (SSM, ECR, CW)
├── security_groups.tf      # ALB, EC2, RDS, VPC endpoint SGs
├── alb.tf                  # internal ALB, target groups, listener rules
├── ec2.tf                  # launch template, instance, IAM instance profile
├── rds.tf                  # Postgres instance, subnet group, 2 databases
├── s3.tf                   # frontend assets bucket + OAC policy
├── cloudfront.tf           # distribution, S3 origin, ALB origin, behaviors
├── ecr.tf                  # ECR repository for backend/keycloak images
├── iam.tf                  # EC2 role, GitHub OIDC provider + role
├── ssm.tf                  # parameter store for secrets (DB creds, etc.)
├── envs/
│   ├── dev.tfvars          # env_active=false (toggleable), t3.small, db.t3.micro
│   └── prod.tfvars         # env_active=true (always), t3.small, db.t3.micro
└── Makefile                # make up, make down, make status (dev only)
```

---

## 5. Security Posture

| Layer | Control |
|-------|---------|
| Network | No public subnets. No IGW. No NAT. VPC endpoints only. |
| Ingress | CloudFront → ALB (prefix list restricted). ALB → EC2 (SG). EC2 → RDS (SG). |
| Access | SSM Session Manager only. No SSH. No bastion. |
| Secrets | SSM Parameter Store (SecureString) or Secrets Manager for DB creds, Keycloak admin. |
| TLS | CloudFront terminates public TLS. ALB can use internal ACM cert. |
| CI/CD Auth | GitHub OIDC federation. No long-lived AWS keys. |
| S3 | Private bucket. OAC for CloudFront. Block all public access. |
| IAM | Least privilege. Separate roles for EC2, CI/CD. |

---

## 6. Cost Estimate (Minimal)

| Resource | Spec | ~Monthly Cost |
|----------|------|---------------|
| EC2 | t3.small (2 vCPU, 2GB) | ~$15 |
| RDS | db.t3.micro (single-AZ) | ~$13 |
| ALB | internal | ~$16 + LCU |
| CloudFront | low traffic tier | ~$1-5 |
| S3 | frontend assets | < $1 |
| VPC Endpoints | ~5 interface endpoints | ~$36 (7.2/ea) |
| ECR | image storage | < $1 |
| **Total** | | **~$85-90/mo** |

Note: VPC endpoints are the biggest chunk. If cost is a concern, you could add a NAT
gateway instead (~$32/mo + data) and drop the interface endpoints, but then traffic
to AWS services goes through NAT → IGW → internet → AWS, not the backbone. Tradeoff.

---

## 7. On-Demand Environment (Spin Up / Spin Down)

The environment doesn't need to be running all the time. Expensive resources are controlled
by a single Terraform variable `env_active` (default: `false`). Cheap/free resources stay
deployed permanently.

### 7.1 What's Always On vs. On-Demand

```
  ALWAYS ON (free or near-free)        ON-DEMAND (env_active = true)
  ─────────────────────────────        ──────────────────────────────
  ✓ VPC + subnets + route tables       ⏻ EC2 instance
  ✓ Security groups                    ⏻ RDS Postgres
  ✓ S3 bucket (frontend assets)        ⏻ ALB + target groups
  ✓ CloudFront distribution            ⏻ VPC endpoints (interface)
  ✓ ECR repository (images stored)
  ✓ IAM roles + policies
  ✓ SSM parameters (secrets)
  ✓ S3 gateway VPC endpoint
```

VPC interface endpoints move to on-demand too — they're $7.20/ea/month and only needed
when EC2 is running.

### 7.2 How It Works

```
  Developer                         Terraform                        AWS
     │                                  │                              │
     │  make up                         │                              │
     │  (sets env_active=true)          │                              │
     │─────────────────────────────────►│                              │
     │                                  │  terraform apply             │
     │                                  │─────────────────────────────►│
     │                                  │  create: VPC endpoints       │
     │                                  │  create: RDS                 │
     │                                  │  create: ALB + TG            │
     │                                  │  create: EC2                 │
     │                                  │  update: CloudFront (add     │
     │                                  │    ALB origin)               │
     │                                  │◄─────────────────────────────│
     │◄─────────────────────────────────│  done                        │
     │                                  │                              │
     │  (use the app via CloudFront)    │                              │
     │                                  │                              │
     │  make down                       │                              │
     │  (sets env_active=false)         │                              │
     │─────────────────────────────────►│                              │
     │                                  │  terraform apply             │
     │                                  │─────────────────────────────►│
     │                                  │  destroy: EC2                │
     │                                  │  destroy: ALB + TG           │
     │                                  │  destroy: RDS                │
     │                                  │  destroy: VPC endpoints      │
     │                                  │  update: CloudFront (remove  │
     │                                  │    ALB origin, /api/* → S3   │
     │                                  │    returns maintenance page) │
     │                                  │◄─────────────────────────────│
     │◄─────────────────────────────────│  done                        │
```

### 7.3 CLI Commands

```bash
# Spin up the environment
make up
# → runs: terraform apply -var="env_active=true" -auto-approve

# Spin down the environment
make down
# → runs: terraform apply -var="env_active=false" -auto-approve

# Check current state
make status
# → runs: terraform output env_active
```

### 7.4 Terraform Implementation Pattern

Resources gated by `count = var.env_active ? 1 : 0`:
- `aws_instance` (EC2)
- `aws_db_instance` (RDS)
- `aws_lb` + `aws_lb_target_group` + `aws_lb_listener` (ALB)
- `aws_vpc_endpoint` (interface endpoints only, not S3 gateway)

CloudFront behaviors update dynamically:
- When `env_active = true`: `/api/*` and `/auth/*` → ALB origin
- When `env_active = false`: `/api/*` and `/auth/*` → S3 origin (serves a static maintenance/offline JSON or page)

### 7.5 RDS Data Persistence

Since RDS gets destroyed on `make down`, you need a strategy for data:

| Option | Pros | Cons |
|--------|------|------|
| A) RDS final snapshot + restore | Data persists across cycles. Automatic. | ~5-10 min restore time. Snapshot storage cost (pennies). |
| B) Keep RDS always on, only toggle EC2+ALB | No data loss risk. Faster spin-up. | ~$13/mo even when idle. |
| C) Treat as ephemeral (seed on boot) | Simplest. Good for dev. | Lose data every cycle. |

Recommended: Option A for production-like, Option C for dev/testing.

### 7.6 Multi-Environment Isolation (Dev vs. Prod)

Production is NEVER affected by `make up` / `make down`. Only dev/testing can be toggled.
Production can only be changed through CI/CD.

This is achieved with separate Terraform workspaces and environment-specific tfvars:

```
infra/
├── envs/
│   ├── dev.tfvars        # env_active supported, smaller instances
│   └── prod.tfvars       # env_active always true, locked down
```

```
  ┌──────────────────────────────────────────────────────────────────┐
  │                        Terraform State                            │
  │                                                                  │
  │   s3://my-tf-state/dev/terraform.tfstate    ← make up/down       │
  │   s3://my-tf-state/prod/terraform.tfstate   ← CI/CD only         │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
```

#### How it's enforced:

```
  Developer (local)                    CI/CD (GitHub Actions)
  ─────────────────                    ──────────────────────
  ✓ make up    (dev only)              ✓ deploy to dev
  ✓ make down  (dev only)              ✓ deploy to prod
  ✓ make status (dev only)             ✓ terraform apply (prod)
  ✗ CANNOT touch prod                  ✗ CANNOT make down prod
```

Enforcement mechanisms:
- Makefile hardcodes `ENV=dev` for `make up` / `make down`
- Prod tfvars has `env_active = true` always (variable ignored / overridden)
- CI/CD IAM role has permissions for both envs
- Developer IAM role scoped to dev state only (S3 bucket policy on state file)
- Prod terraform apply only runs in GitHub Actions after manual approval

#### Resource separation:

Each environment gets its own isolated set of resources:

```
  DEV                                  PROD
  ───                                  ────
  VPC: 10.0.0.0/16                     VPC: 10.1.0.0/16
  EC2: t3.small (on-demand toggle)     EC2: t3.small (always on)
  RDS: db.t3.micro (on-demand toggle)  RDS: db.t3.micro (always on)
  ALB: internal (on-demand toggle)     ALB: internal (always on)
  CloudFront: dev.example.com          CloudFront: app.example.com
  S3: dev-frontend-assets              S3: prod-frontend-assets
  ECR: shared (same images, diff tags) ECR: shared (same images, diff tags)
```

ECR is shared — both envs pull from the same repo but use different image tags:
- Dev: `backend:latest` or `backend:<branch-sha>`
- Prod: `backend:<release-tag>` (only promoted through CI/CD)

#### Updated CLI:

```bash
# Dev environment (developer can run locally)
make up          # → terraform apply -var-file=envs/dev.tfvars -var="env_active=true"
make down        # → terraform apply -var-file=envs/dev.tfvars -var="env_active=false"
make status      # → terraform output -state=dev

# Prod environment (CI/CD only — these commands exist but are gated)
make deploy-prod # → only works in GitHub Actions (checks CI env var)
```

### 7.7 Updated Cost Estimate

| Scenario | Dev ~Monthly | Prod ~Monthly |
|----------|-------------|---------------|
| Dev off, Prod on (typical) | ~$1-2 | ~$85-90 |
| Dev 8hrs/day weekdays, Prod on | ~$25-30 | ~$85-90 |
| Both always on | ~$85-90 | ~$85-90 |

---

## 8. CI/CD Pipeline with Multi-Environment

### 8.1 Updated Pipeline Flow

```
  push to main
       │
       ├── Frontend changed?
       │   └── Yes → build → sync S3 (dev) → invalidate CF (dev)
       │                    → sync S3 (prod) → invalidate CF (prod)
       │         (frontend deploys to both — static assets, always safe)
       │
       └── Backend changed?
           └── Yes → build → push to ECR (tagged with SHA + "latest")
                 │
                 ├── Dev:  is env_active?
                 │         ├── Yes → SSM deploy to dev EC2
                 │         └── No  → skip (next `make up` picks it up)
                 │
                 └── Prod: manual approval gate
                           └── approved → SSM deploy to prod EC2
```

### 8.2 Promotion Flow (Dev → Prod)

```
  Developer pushes to main
       │
       ▼
  Build + test + push to ECR as :latest and :<sha>
       │
       ├──► Dev auto-deploys (if up)
       │
       └──► Prod requires manual approval in GitHub Actions
             │
             └── Approved → tag image as :<release> → deploy to prod EC2
```

### 8.3 Spin-Up Includes Latest Deploy (Dev only)

The EC2 user data script always pulls the `latest` tagged image from ECR on boot.
So `make up` automatically gets the most recent backend build — no separate deploy step needed.

```
  make up
    │
    ├── terraform creates EC2
    │     └── user data runs:
    │           docker pull <ecr>/backend:latest
    │           docker pull <ecr>/keycloak:latest
    │           docker-compose up -d
    │
    └── terraform creates RDS
          └── (restore from snapshot or run seed)
```
