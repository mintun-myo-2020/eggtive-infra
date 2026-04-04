# Architecture Diagram — Eggtive SPM (Dev Environment)

## Full System Overview

```
                            ┌─────────────────────────────────────────┐
                            │            INTERNET                      │
                            └──────────────────┬──────────────────────┘
                                               │
                         ┌─────────────────────┼─────────────────────┐
                         │                     │                     │
                    User Browser          Developer            GitHub Actions
                         │               (laptop)             (CI/CD)
                         │                     │                     │
                         │  HTTPS              │ SSM Session         │ OIDC
                         │                     │ Manager             │ Federation
                         ▼                     │                     ▼
┌─ Route 53 (Public) ────────────────────┐     │    ┌────────────────────────────┐
│                                        │     │    │  IAM                       │
│  eggtive.com (hosted zone)             │     │    │                            │
│  └─ spm.eggtive.com ──► CloudFront     │     │    │  EC2 Role:                 │
│                                        │     │    │  ├─ SSM managed instance   │
│  ACM Certificate (us-east-1)           │     │    │  ├─ S3 read (artifacts)    │
│  └─ spm.eggtive.com (DNS validated)    │     │    │  ├─ SSM params read        │
│                                        │     │    │  ├─ CloudWatch logs write  │
│                                        │     │    │  └─ Bedrock invoke model   │
└────────────────────────────────────────┘     │    │                            │
                         │                     │    │  GitHub Actions Role:       │
                         ▼                     │    │  ├─ S3 read/write          │
              ┌──────────────────┐             │    │  ├─ CloudFront invalidate  │
              │   CloudFront      │             │    │  ├─ SSM send-command      │
              │   (always on)     │             │    │  └─ TF state S3/DynamoDB  │
              │                   │             │    └────────────────────────────┘
              │  TLS termination  │             │
              │  spm.eggtive.com  │             │
              └───────┬──────────┘             │
                      │                        │
         ┌────────────┼────────────┐           │
         │            │            │           │
     /*  │    /api/*  │  /auth/*   │           │
         │            │            │           │
         ▼            ▼            ▼           │
```
```
  ┌──────────────┐
  │ S3 (OAC)     │◄──── /* (default behavior)
  │              │◄──── /api/*, /auth/* (when env_active=false → maintenance JSON)
  │ Frontend     │
  │ Bucket       │
  │ (always on)  │
  │              │
  │ - index.html │
  │ - static/    │
  │ - api/       │
  │   maintenance│
  │   .json      │
  └──────────────┘

  ┌──────────────┐
  │ S3           │
  │ Artifacts    │
  │ Bucket       │
  │ (always on)  │
  │              │
  │ - spm-app.jar│
  │ - keycloak/  │
  │   keycloak   │
  │   .tar.gz    │
  └──────────────┘
```

## VPC Detail (when env_active = true)

```
┌─ VPC 10.0.0.0/16 ──────────────────────────────────────────────────────────────┐
│                                                                                 │
│  Internet Gateway (attached, no routes — required by CloudFront VPC origins)    │
│                                                                                 │
│  ┌─ Private Subnet A (ap-southeast-1a) ─┐  ┌─ Private Subnet B (1b) ────────┐ │
│  │          10.0.1.0/24                  │  │       10.0.2.0/24              │ │
│  │                                       │  │                               │ │
│  │  ┌─────────────────────────────────┐  │  │                               │ │
│  │  │  ALB (internal, spans both AZs) │◄─┼──┤                               │ │
│  │  │  SG: CloudFront prefix list    │  │  │                               │ │
│  │  │  CloudFront VPC origin ENI ──►  │  │  │                               │ │
│  │  └──────────┬──────────┬───────────┘  │  │                               │ │
│  │             │          │              │  │                               │ │
│  │     /api/*  │  /auth/* │              │  │                               │ │
│  │     :8080   │  :8443   │              │  │                               │ │
│  │             ▼          ▼              │  │                               │ │
│  │  ┌──────────────┐ ┌──────────────┐   │  │                               │ │
│  │  │ EC2: Backend  │ │EC2: Keycloak │   │  │                               │ │
│  │  │ t3.small      │ │t3.small      │   │  │                               │ │
│  │  │ AL2023 + JDK21│ │AL2023 + JDK21│   │  │                               │ │
│  │  │               │ │              │   │  │                               │ │
│  │  │ systemd:      │ │systemd:      │   │  │                               │ │
│  │  │ backend.jar   │ │kc.sh start   │   │  │                               │ │
│  │  │               │ │              │   │  │                               │ │
│  │  │ SG: ALB→8080  │ │SG: ALB→8443  │   │  │                               │ │
│  │  │               │ │              │   │  │                               │ │
│  │  │ Tags:         │ │Tags:         │   │  │                               │ │
│  │  │ Service=      │ │Service=      │   │  │                               │ │
│  │  │  backend      │ │  keycloak    │   │  │                               │ │
│  │  │ Env=dev       │ │Env=dev       │   │  │                               │ │
│  │  └──────┬────────┘ └──────┬───────┘   │  │                               │ │
│  │         │                 │           │  │                               │ │
│  │         └────────┬────────┘           │  │                               │ │
│  │                  ▼                    │  │                               │ │
│  │  ┌──────────────────────────────┐     │  │  ┌──────────────────────┐     │ │
│  │  │  RDS PostgreSQL 16           │     │  │  │  (DB subnet group    │     │ │
│  │  │  db.t3.micro, single-AZ     │     │  │  │   spans both AZs)    │     │ │
│  │  │  SG: backend→5432           │     │  │  │                      │     │ │
│  │  │      keycloak→5432          │     │  │  │                      │     │ │
│  │  │                              │     │  │  │                      │     │ │
│  │  │  Databases:                  │     │  │  │                      │     │ │
│  │  │  ├─ appdb                    │     │  │  │                      │     │ │
│  │  │  └─ keycloakdb               │     │  │  │                      │     │ │
│  │  │                              │     │  │  │                      │     │ │
│  │  │  Final snapshot on destroy   │     │  │  │                      │     │ │
│  │  └──────────────────────────────┘     │  │  └──────────────────────┘     │ │
│  │                                       │  │                               │ │
│  └───────────────────────────────────────┘  └───────────────────────────────┘ │
│                                                                                 │
│  ┌─ VPC Endpoints ──────────────────────────────────────────────────────────┐   │
│  │                                                                          │   │
│  │  Gateway (always on, free):          Interface (on-demand):              │   │
│  │  └─ S3                               ├─ SSM          ($7.20/mo)         │   │
│  │                                      ├─ SSM Messages ($7.20/mo)         │   │
│  │                                      ├─ EC2 Messages ($7.20/mo)         │   │
│  │                                      ├─ CloudWatch   ($7.20/mo)         │   │
│  │                                      │    Logs                           │   │
│  │                                      └─ Bedrock      ($7.20/mo)         │   │
│  │                                           Runtime                        │   │
│  │  SG: HTTPS (443) from VPC CIDR                                          │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─ Route 53 Private Hosted Zone ───────────────────────────────────────────┐   │
│  │  internal.dev.eggtive-spm                                                │   │
│  │                                                                          │   │
│  │  backend.internal.dev.eggtive-spm  → EC2 backend private IP              │   │
│  │  keycloak.internal.dev.eggtive-spm → EC2 keycloak private IP             │   │
│  │  db.internal.dev.eggtive-spm       → CNAME → RDS endpoint               │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## SSM Parameter Store (Secrets)

```
/eggtive-spm/dev/
├── db/
│   ├── url            (jdbc:postgresql://rds-endpoint:5432/appdb)
│   ├── username       (dbadmin)
│   └── password       (auto-generated, SecureString)
├── keycloak/
│   ├── url            (http://keycloak.internal.dev.eggtive-spm:8443/auth/realms/master)
│   ├── admin/password (auto-generated, SecureString)
│   ├── client-secret  (auto-generated, SecureString — for spm-backend client)
│   ├── db/url         (jdbc:postgresql://rds-endpoint:5432/keycloakdb)
│   ├── db/username    (dbadmin)
│   └── db/password    (auto-generated, SecureString)
```

## CI/CD Flow

```
┌─ Infra Repo (this repo) ────────────────────────────────────────────────┐
│                                                                          │
│  push to main (infra/** changed)                                         │
│       │                                                                  │
│       ▼                                                                  │
│  GitHub Actions (.github/workflows/infra.yml)                            │
│       │                                                                  │
│       ├── terraform fmt -check                                           │
│       ├── terraform plan → review                                        │
│       └── terraform apply (after approval)                               │
│                                                                          │
│  Local only:                                                             │
│       make up   → terraform apply -var="env_active=true"                 │
│       make down → terraform apply -var="env_active=false"                │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

┌─ App Repo ──────────────────────────────────────────────────────────────┐
│                                                                          │
│  push to main                                                            │
│       │                                                                  │
│       ├── frontend/** changed?                                           │
│       │   └── npm build → S3 sync → CloudFront invalidate                │
│       │                                                                  │
│       └── backend/** changed?                                            │
│           └── gradle build → JAR → S3 artifacts                          │
│               └── SSM send-command → EC2 deploy.sh                       │
│                   (targets by tag: Service=backend, Environment=dev)      │
│                                                                          │
│  Auth: GitHub OIDC → IAM Role (no long-lived keys)                       │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Terraform State

```
┌─ S3: eggtive-spm-terraform-state ─┐    ┌─ DynamoDB: terraform-locks ─┐
│                                    │    │                              │
│  dev/terraform.tfstate             │    │  LockID (prevents            │
│  (prod/ added later)               │    │  concurrent applies)         │
│                                    │    │                              │
│  Versioning: enabled               │    │  Billing: pay-per-request    │
│  Public access: blocked            │    │                              │
└────────────────────────────────────┘    └──────────────────────────────┘
```

## On/Off Toggle (Dev Only)

```
  env_active = false (make down)          env_active = true (make up)
  ──────────────────────────────          ─────────────────────────────
  ✓ VPC, subnets, route tables            ✓ everything from left PLUS:
  ✓ Internet gateway (no routes)          ✓ EC2 backend
  ✓ Security groups                       ✓ EC2 keycloak
  ✓ S3 buckets (frontend + artifacts)     ✓ RDS PostgreSQL
  ✓ CloudFront (→ S3 maintenance)         ✓ ALB + 2 target groups
  ✓ Route 53 private zone (empty)         ✓ VPC interface endpoints (×5)
  ✓ IAM roles + policies                  ✓ Route 53 A/CNAME records
  ✓ SSM parameters                        ✓ CloudFront VPC origin → ALB
  ✓ S3 gateway VPC endpoint
  ✓ ACM cert + DNS records
  ✓ GitHub OIDC provider + role

  Cost: ~$1-2/mo                          Cost: ~$90-95/mo
```

## Boot Resilience

EC2 services use systemd's `ExecStartPre` with `Restart=always` for self-healing:
- `ExecStartPre` downloads artifacts from S3 and reads config from SSM
- If S3 or SSM isn't ready, the service fails and systemd retries every 30s
- `StartLimitIntervalSec=0` means systemd never gives up
- `depends_on` in Terraform ensures RDS + SSM + VPC endpoints exist before EC2s

The 3-phase `make up` eliminates most race conditions:
1. Phase 1: creates S3 buckets (env_active=false)
2. Phase 2: uploads artifacts to S3
3. Phase 3: creates EC2s (env_active=true) — artifacts already in S3

Keycloak bootstrap on fresh DB:
1. Starts temporarily with `KEYCLOAK_ADMIN` env vars → creates admin user
2. Imports realm via `kcadm.sh` (creates spm realm, clients, roles)
3. Sets spm-backend client secret from SSM
4. Marks bootstrap done so subsequent restarts skip this
