# Infrastructure Plan v2 — No Containers, JVM on EC2

## 1. Overview

Deploy a full-stack application (React frontend + JVM backend + Keycloak) on AWS with:
- Minimal footprint (single EC2, single RDS)
- No containers — backend JAR + Keycloak distribution run directly on EC2 via systemd
- Zero public exposure except through CloudFront
- All internal traffic on AWS backbone (VPC endpoints, no NAT gateway)
- Infrastructure as Code via Terraform
- CI/CD pipeline for automated builds and deploys
- On-demand dev environment: `make up` / `make down`
- Production isolated: only deployable through CI/CD with manual approval

---

## 2. Architecture

### 2.1 Network Topology

```
┌──────────────────────────────────────────────────────────────────────┐
│                            AWS Account                                │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     VPC (per env)                               │  │
│  │          dev: 10.0.0.0/16    prod: 10.1.0.0/16                 │  │
│  │                                                                │  │
│  │  ┌──────────────────────┐  ┌──────────────────────┐            │  │
│  │  │ Private Subnet A     │  │ Private Subnet B      │           │  │
│  │  │ (AZ-a)               │  │ (AZ-b)                │           │  │
│  │  │                      │  │                       │           │  │
│  │  │  ┌────────────────┐  │  │                       │           │  │
│  │  │  │     ALB         │◄─┼──┤  (ALB spans both AZs) │          │  │
│  │  │  │  (internal)     │  │  │                       │           │  │
│  │  │  └───────┬────────┘  │  │                       │           │  │
│  │  │          │           │  │                       │           │  │
│  │  │  ┌───────▼────────┐  │  │                       │           │  │
│  │  │  │  EC2 (t3.small) │  │  │                       │           │  │
│  │  │  │                 │  │  │                       │           │  │
│  │  │  │  systemd:       │  │  │                       │           │  │
│  │  │  │  ├─ backend.jar │  │  │                       │           │  │
│  │  │  │  │  :8080       │  │  │                       │           │  │
│  │  │  │  └─ keycloak    │  │  │                       │           │  │
│  │  │  │     :8443       │  │  │                       │           │  │
│  │  │  │                 │  │  │                       │           │  │
│  │  │  │  JDK 21 (AMI)  │  │  │                       │           │  │
│  │  │  └────────────────┘  │  │                       │           │  │
│  │  │                      │  │                       │           │  │
│  │  │  ┌────────────────┐  │  │  ┌────────────────┐   │           │  │
│  │  │  │  RDS Postgres   │  │  │  │  (subnet group │   │           │  │
│  │  │  │  - app_db       │  │  │  │   spans AZs)   │   │           │  │
│  │  │  │  - keycloak_db  │  │  │  │                │   │           │  │
│  │  │  └────────────────┘  │  │  └────────────────┘   │           │  │
│  │  └──────────────────────┘  └───────────────────────┘           │  │
│  │                                                                │  │
│  │  VPC Endpoints:                                                │  │
│  │  - S3 gateway (always on)                                      │  │
│  │  - SSM, SSM Messages, EC2 Messages (on-demand in dev)          │  │
│  │  - CloudWatch Logs (on-demand in dev)                          │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌─────────────────────┐    ┌──────────────────────┐                 │
│  │  S3 Bucket (per env) │    │  S3 Artifact Bucket   │                │
│  │  React build assets  │    │  (shared)              │                │
│  │  - index.html        │    │  - backend.jar         │                │
│  │  - static/           │    │  - keycloak.tar.gz     │                │
│  └─────────────────────┘    └──────────────────────┘                 │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Request Flow (User → App)

```
    User's Browser
         │
         │  HTTPS (CloudFront domain or custom)
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
  │ (OAC)     │          │ (internal)    │
  │           │          │               │
  │ React SPA │          │ ┌───────────┐ │
  │ assets    │          │ │ /api/* ──► │─┼──► EC2:8080 (backend.jar)
  └──────────┘          │ │ /auth/* ─► │─┼──► EC2:8443 (keycloak)
                         │ └───────────┘ │
                         └──────────────┘

  When env is DOWN (dev only):
  /api/* and /auth/* → S3 maintenance page (503)
```

### 2.3 What Runs on EC2

No containers. Two JVM processes managed by systemd:

```
  EC2 (Amazon Linux 2023 + JDK 21)
  │
  ├── /opt/app/
  │   ├── backend.jar              ← your app
  │   └── application.yml          ← config (DB url, keycloak url, etc.)
  │
  ├── /opt/keycloak/
  │   ├── bin/kc.sh                ← keycloak distribution
  │   └── conf/keycloak.conf       ← keycloak config
  │
  ├── /etc/systemd/system/
  │   ├── backend.service          ← systemd unit for backend
  │   └── keycloak.service         ← systemd unit for keycloak
  │
  └── /opt/deploy/
      └── deploy.sh                ← script: download from S3, restart services
```

systemd gives you:
- Auto-restart on crash
- Proper logging to journald → CloudWatch agent
- Ordered startup (keycloak before backend)
- Clean shutdown

### 2.4 Access & Management

```
  Developer laptop
       │
       │  AWS SSM Session Manager (no SSH, no bastion)
       ▼
  ┌──────────┐
  │   EC2     │  ← IAM instance profile with SSM + S3 read permissions
  └──────────┘
```

---

## 3. Artifact Storage (replaces ECR)

No Docker registry. Artifacts go to S3:

```
  s3://myapp-artifacts/
  ├── backend/
  │   ├── latest/backend.jar           ← always points to newest
  │   └── builds/<sha>/backend.jar     ← versioned by git SHA
  └── keycloak/
      └── keycloak-25.0.tar.gz         ← pinned version, uploaded once
```

CI builds the JAR, uploads to S3. EC2 pulls from S3 on deploy (via VPC gateway endpoint — free, on backbone).

---

## 4. CI/CD Pipeline

### 4.1 Pipeline Architecture

```
  ┌──────────────┐
  │  GitHub Repo  │
  │  (mono-repo)  │
  │  ├── frontend/│
  │  ├── backend/ │
  │  └── infra/   │
  └──────┬───────┘
         │
         │  push to main
         ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                    GitHub Actions                             │
  │                                                              │
  │  ┌─────────────────────────────────────────────────────────┐ │
  │  │  Job: detect-changes                                    │ │
  │  └────────┬──────────────┬──────────────┬──────────────────┘ │
  │           │              │              │                     │
  │     ┌─────▼─────┐ ┌─────▼─────┐ ┌─────▼──────┐             │
  │     │ Frontend   │ │ Backend   │ │ Infra      │             │
  │     │            │ │           │ │            │             │
  │     │ npm ci     │ │ ./gradlew │ │ tf fmt     │             │
  │     │ npm test   │ │   build   │ │ tf plan    │             │
  │     │ npm build  │ │ ./gradlew │ │ (approve)  │             │
  │     │            │ │   test    │ │ tf apply   │             │
  │     │ s3 sync    │ │           │ │            │             │
  │     │ (both envs)│ │ upload    │ │            │             │
  │     │            │ │ JAR → S3  │ │            │             │
  │     │ invalidate │ │           │ │            │             │
  │     │ CloudFront │ │ deploy:   │ │            │             │
  │     │            │ │ dev auto  │ │            │             │
  │     │            │ │ prod gate │ │            │             │
  │     └────────────┘ └───────────┘ └────────────┘             │
  └──────────────────────────────────────────────────────────────┘
```

### 4.2 Backend Deploy Mechanism

No Docker. CI uploads JAR to S3, then triggers deploy via SSM:

```
  GitHub Actions
       │
       │ 1. ./gradlew build → backend.jar
       │ 2. aws s3 cp backend.jar s3://myapp-artifacts/backend/builds/<sha>/
       │ 3. aws s3 cp backend.jar s3://myapp-artifacts/backend/latest/
       │
       │ 4. Deploy (if env is up):
       │    aws ssm send-command --document-name "AWS-RunShellScript" \
       │      --targets "Key=tag:Environment,Values=dev" \
       │      --parameters 'commands=["bash /opt/deploy/deploy.sh"]'
       ▼
  EC2 runs deploy.sh:
       │
       │  aws s3 cp s3://myapp-artifacts/backend/latest/backend.jar /opt/app/
       │  systemctl restart backend
       ▼
  Done. New version running.
```

For prod: same flow but with manual approval gate in GitHub Actions,
and targets `Environment=prod`.

### 4.3 GitHub Actions → AWS Auth

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
  │ - S3 (frontend +  │
  │   artifacts)      │
  │ - SSM (deploy)    │
  │ - CloudFront      │
  │   (invalidation)  │
  │ - Terraform state │
  │   (S3 + DynamoDB) │
  └──────────────────┘
```

---

## 5. Terraform Structure

```
infra/
├── main.tf                 # provider, backend (S3 + DynamoDB)
├── variables.tf            # env_active, environment, instance_type, etc.
├── outputs.tf              # CloudFront URL, ALB DNS, EC2 instance ID
├── vpc.tf                  # VPC, private subnets, route tables
├── vpc_endpoints.tf        # S3 gateway (always) + interface endpoints (on-demand dev)
├── security_groups.tf      # ALB, EC2, RDS, VPC endpoint SGs
├── alb.tf                  # internal ALB, target groups, listener rules
├── ec2.tf                  # instance, IAM profile, user data (install JDK, systemd units)
├── rds.tf                  # Postgres, subnet group, snapshot logic
├── s3.tf                   # frontend bucket (per env) + artifacts bucket (shared)
├── cloudfront.tf           # distribution, S3 + ALB origins, behaviors
├── iam.tf                  # EC2 role, GitHub OIDC provider + role
├── ssm.tf                  # parameter store (DB creds, keycloak admin, etc.)
├── envs/
│   ├── dev.tfvars          # env_active toggleable, smaller if needed
│   └── prod.tfvars         # env_active=true always
└── Makefile                # make up, make down, make status (dev only)
```

---

## 6. EC2 User Data (AMI Bootstrap)

On first boot (or `make up` creating a new instance), user data does:

```bash
#!/bin/bash
# Install JDK
dnf install -y java-21-amazon-corretto-headless

# Create app user
useradd -r -s /bin/false appuser

# Download artifacts from S3
aws s3 cp s3://myapp-artifacts/backend/latest/backend.jar /opt/app/
aws s3 cp s3://myapp-artifacts/keycloak/keycloak-25.0.tar.gz /opt/
tar -xzf /opt/keycloak-25.0.tar.gz -C /opt/keycloak --strip-components=1

# Install systemd units (baked into AMI or pulled from S3)
# ... backend.service, keycloak.service

# Pull config from SSM Parameter Store
# ... DB_URL, DB_PASSWORD, KC_ADMIN_PASSWORD, etc.

# Start services
systemctl enable --now keycloak
systemctl enable --now backend
```

Option: bake a custom AMI with JDK + Keycloak pre-installed via Packer.
Then user data only pulls the backend.jar + config. Faster boot time.

---

## 7. On-Demand Environment (Dev Only)

### 7.1 What's Always On vs. On-Demand

```
  ALWAYS ON (free or near-free)        ON-DEMAND (env_active = true)
  ─────────────────────────────        ──────────────────────────────
  ✓ VPC + subnets + route tables       ⏻ EC2 instance
  ✓ Security groups                    ⏻ RDS Postgres
  ✓ S3 buckets (frontend + artifacts)  ⏻ ALB + target groups
  ✓ CloudFront distribution            ⏻ VPC interface endpoints
  ✓ IAM roles + policies
  ✓ SSM parameters (secrets)
  ✓ S3 gateway VPC endpoint
```

### 7.2 CLI Commands

```bash
make up          # terraform apply -var-file=envs/dev.tfvars -var="env_active=true"
make down        # terraform apply -var-file=envs/dev.tfvars -var="env_active=false"
make status      # terraform output -state=dev
make deploy-dev  # SSM: trigger deploy.sh on dev EC2 (if up)
```

`make up` creates EC2 → user data pulls latest JAR from S3 → app is running.
No separate deploy step needed on spin-up.

### 7.3 Multi-Environment Isolation

```
  Developer (local)                    CI/CD (GitHub Actions)
  ─────────────────                    ──────────────────────
  ✓ make up/down (dev only)            ✓ deploy to dev (auto)
  ✓ make status  (dev only)            ✓ deploy to prod (manual gate)
  ✗ CANNOT touch prod                  ✓ terraform apply (both envs)
```

Enforced by:
- Makefile hardcodes `ENV=dev`
- Developer IAM role scoped to dev Terraform state only
- Prod deploys require manual approval in GitHub Actions

### 7.4 RDS Data Persistence

| Option | Pros | Cons |
|--------|------|------|
| A) Final snapshot + restore | Data persists. Automatic. | ~5-10 min restore. |
| B) Ephemeral (seed on boot) | Simplest. Good for dev. | Lose data each cycle. |

---

## 8. Security Posture

| Layer | Control |
|-------|---------|
| Network | No public subnets. No IGW. No NAT. VPC endpoints only. |
| Ingress | CloudFront → ALB (prefix list). ALB → EC2 (SG). EC2 → RDS (SG). |
| Access | SSM Session Manager only. No SSH. No bastion. |
| Secrets | SSM Parameter Store (SecureString) for DB creds, Keycloak admin. |
| TLS | CloudFront terminates public TLS. ALB internal. |
| CI/CD Auth | GitHub OIDC federation. No long-lived AWS keys. |
| S3 | Private buckets. OAC for CloudFront. Block all public access. |
| IAM | Least privilege. Separate roles for EC2, CI/CD, developer. |
| Artifacts | S3 bucket with versioning. EC2 pulls via S3 gateway endpoint. |

---

## 9. Cost Estimate

| Resource | Spec | ~Monthly (always on) |
|----------|------|---------------------|
| EC2 | t3.small | ~$15 |
| RDS | db.t3.micro (single-AZ) | ~$13 |
| ALB | internal | ~$16 + LCU |
| CloudFront | low traffic | ~$1-5 |
| S3 | frontend + artifacts | < $1 |
| VPC Endpoints | ~4 interface | ~$29 |
| **Per env total** | | **~$75-80** |

| Scenario | Dev | Prod | Total |
|----------|-----|------|-------|
| Dev off, Prod on | ~$1-2 | ~$75-80 | ~$77-82 |
| Dev 8hrs weekdays, Prod on | ~$20-25 | ~$75-80 | ~$95-105 |
| Both always on | ~$75-80 | ~$75-80 | ~$150-160 |

Cheaper than v1 — no ECR costs, no Docker overhead, fewer VPC endpoints
(dropped ECR API + ECR DKR endpoints since we use S3 for artifacts).

---

## 10. What Changed from v1 (Container-based)

| Aspect | v1 (Docker) | v2 (JVM direct) |
|--------|-------------|-----------------|
| Runtime | docker-compose | systemd + JVM |
| Artifact store | ECR (Docker images) | S3 (JAR + Keycloak tarball) |
| Deploy mechanism | docker pull + compose up | S3 download + systemctl restart |
| VPC endpoints needed | S3, SSM×3, ECR×2, CW = 7 | S3, SSM×3, CW = 5 (saved ~$14/mo) |
| EC2 user data | install Docker, pull images | install JDK, download JARs |
| Build pipeline | docker build + push | gradle build + S3 upload |
| Complexity | Medium (Docker layer) | Lower (just JVM processes) |
| Keycloak | Docker image | Standalone distribution |
