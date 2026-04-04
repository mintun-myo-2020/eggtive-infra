# Infrastructure Plan v3 — Separate EC2s, Internal DNS, No Containers

## 1. Overview

Deploy a full-stack application (React frontend + JVM backend + Keycloak) on AWS with:
- Separate EC2 instances for backend and Keycloak (isolated lifecycles)
- No containers — JVM processes run directly via systemd
- Route 53 Private Hosted Zone for internal service discovery
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
┌───────────────────────────────────────────────────────────────────────────┐
│                              AWS Account                                   │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                       VPC (per env)                                  │  │
│  │            dev: 10.0.0.0/16    prod: 10.1.0.0/16                    │  │
│  │                                                                     │  │
│  │  ┌──────────────────────────┐  ┌──────────────────────────┐         │  │
│  │  │  Private Subnet A (AZ-a) │  │  Private Subnet B (AZ-b) │         │  │
│  │  │       10.x.1.0/24        │  │       10.x.2.0/24        │         │  │
│  │  │                          │  │                          │         │  │
│  │  │  ┌──────────────────┐    │  │                          │         │  │
│  │  │  │      ALB          │◄───┤  (ALB spans both AZs)     │         │  │
│  │  │  │   (internal)      │    │  │                          │         │  │
│  │  │  └──┬──────────┬─────┘    │  │                          │         │  │
│  │  │     │          │          │  │                          │         │  │
│  │  │     │ /api/*   │ /auth/*  │  │                          │         │  │
│  │  │     ▼          ▼          │  │                          │         │  │
│  │  │  ┌────────┐ ┌──────────┐  │  │                          │         │  │
│  │  │  │EC2:    │ │EC2:      │  │  │                          │         │  │
│  │  │  │Backend │ │Keycloak  │  │  │                          │         │  │
│  │  │  │:8080   │ │:8443     │  │  │                          │         │  │
│  │  │  │t3.small│ │t3.small  │  │  │                          │         │  │
│  │  │  └───┬────┘ └────┬─────┘  │  │                          │         │  │
│  │  │      │           │        │  │                          │         │  │
│  │  │      │    ┌──────┘        │  │                          │         │  │
│  │  │      │    │               │  │                          │         │  │
│  │  │  ┌───▼────▼────────────┐  │  │  ┌──────────────────┐   │         │  │
│  │  │  │   RDS Postgres      │  │  │  │  (subnet group    │   │         │  │
│  │  │  │   - app_db          │  │  │  │   spans AZs)      │   │         │  │
│  │  │  │   - keycloak_db     │  │  │  │                   │   │         │  │
│  │  │  └─────────────────────┘  │  │  └──────────────────┘   │         │  │
│  │  └──────────────────────────┘  └──────────────────────────┘         │  │
│  │                                                                     │  │
│  │  ┌───────────────────────────────────────────────────────────────┐  │  │
│  │  │  Route 53 Private Hosted Zone: internal.<env>.myapp           │  │  │
│  │  │                                                               │  │  │
│  │  │  backend.internal.<env>.myapp  → EC2 backend private IP       │  │  │
│  │  │  keycloak.internal.<env>.myapp → EC2 keycloak private IP      │  │  │
│  │  │  db.internal.<env>.myapp       → RDS endpoint                 │  │  │
│  │  └───────────────────────────────────────────────────────────────┘  │  │
│  │                                                                     │  │
│  │  VPC Endpoints:                                                     │  │
│  │  - S3 gateway (always on)                                           │  │
│  │  - SSM, SSM Messages, EC2 Messages (on-demand in dev)               │  │
│  │  - CloudWatch Logs (on-demand in dev)                               │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ┌──────────────────────┐    ┌──────────────────────┐                     │
│  │  S3 Bucket (per env)  │    │  S3 Artifact Bucket   │                    │
│  │  React build assets   │    │  (shared)              │                    │
│  │  - index.html         │    │  - backend.jar         │                    │
│  │  - static/            │    │  - keycloak.tar.gz     │                    │
│  └──────────────────────┘    └──────────────────────┘                     │
└───────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Request Flow

```
    User's Browser
         │
         │  HTTPS
         ▼
  ┌──────────────┐
  │  CloudFront   │
  └──────┬───────┘
         │
    ┌────┴──────────────────────┐
    │                           │
    │ /*                        │ /api/*  /auth/*
    ▼                           ▼
  ┌──────────┐           ┌──────────────┐
  │ S3 (OAC) │           │ ALB (internal)│
  │ React SPA│           └──────┬───────┘
  └──────────┘              ┌───┴────┐
                            │        │
                     /api/* │        │ /auth/*
                            ▼        ▼
                    ┌────────┐  ┌──────────┐
                    │Backend │  │ Keycloak  │
                    │EC2     │  │ EC2       │
                    │:8080   │  │ :8443     │
                    └───┬────┘  └────┬─────┘
                        │            │
                        └─────┬──────┘
                              ▼
                        ┌──────────┐
                        │   RDS    │
                        │ Postgres │
                        └──────────┘
```

### 2.3 Internal DNS (Route 53 Private Hosted Zone)

Services find each other via DNS names, not hardcoded IPs:

```
  Route 53 Private Hosted Zone: internal.<env>.myapp
  ──────────────────────────────────────────────────
  backend.internal.dev.myapp    → 10.0.1.x  (backend EC2 private IP)
  keycloak.internal.dev.myapp   → 10.0.1.y  (keycloak EC2 private IP)
  db.internal.dev.myapp         → CNAME → RDS endpoint
```

Why this matters:
- Backend config points to `keycloak.internal.dev.myapp` — no hardcoded IPs
- Backend config points to `db.internal.dev.myapp` — survives RDS restarts
- If you replace an EC2, just update the DNS record (Terraform handles this)
- Clean separation: each service has its own identity

### 2.4 What Runs on Each EC2

```
  EC2: Backend (t3.small)                EC2: Keycloak (t3.small)
  ───────────────────────                ────────────────────────
  /opt/app/                              /opt/keycloak/
  ├── backend.jar                        ├── bin/kc.sh
  └── application.yml                    └── conf/keycloak.conf
      DB_URL=db.internal...                  DB_URL=db.internal...
      KC_URL=keycloak.internal...            KC_HOSTNAME=keycloak.internal...

  /etc/systemd/system/                   /etc/systemd/system/
  └── backend.service                    └── keycloak.service

  /opt/deploy/                           /opt/deploy/
  └── deploy.sh                          └── deploy.sh
```

Each instance is single-purpose. Independent restarts, independent scaling later if needed.

### 2.5 ALB Routing

Single ALB, two target groups:

```
  ALB Listener (:443)
  │
  ├── Rule: /api/*   → Target Group: backend  (EC2 backend :8080)
  ├── Rule: /auth/*  → Target Group: keycloak (EC2 keycloak :8443)
  └── Default        → 404
```

### 2.6 Access & Management

```
  Developer laptop
       │
       │  SSM Session Manager
       ├──────────────────────► EC2 Backend
       └──────────────────────► EC2 Keycloak
```

---

## 3. Artifact Storage

```
  s3://myapp-artifacts/
  ├── backend/
  │   ├── latest/backend.jar
  │   └── builds/<sha>/backend.jar
  └── keycloak/
      └── keycloak-25.0.tar.gz          ← pinned, uploaded once
```

---

## 4. CI/CD Pipeline

### 4.1 Pipeline Architecture

```
  push to main
       │
  ┌────┴──────────────────────────────────────────────────────┐
  │                  GitHub Actions                            │
  │                                                            │
  │  detect-changes                                            │
  │  ┌──────────┬──────────┬──────────┐                        │
  │  │          │          │          │                         │
  │  ▼          ▼          ▼          │                         │
  │ Frontend   Backend    Infra       │                         │
  │                                   │                         │
  │ npm build  gradle     tf plan     │                         │
  │ → S3 sync  build      → approve   │                         │
  │ → CF inv.  → S3 JAR   → tf apply  │                         │
  │ (both env) → SSM dep.             │                         │
  │             dev: auto              │                         │
  │             prod: gate             │                         │
  └────────────────────────────────────┘
```

### 4.2 Backend Deploy

```
  CI: gradle build → upload JAR to S3
       │
       ▼
  SSM send-command → EC2 Backend (by tag)
       │
       ▼
  deploy.sh on EC2:
    aws s3 cp s3://myapp-artifacts/backend/latest/backend.jar /opt/app/
    systemctl restart backend
```

Keycloak rarely changes — deploy manually or via separate workflow when upgrading versions.

### 4.3 Auth: GitHub OIDC → IAM Role (no long-lived keys)

---

## 5. Terraform Structure

```
infra/
├── main.tf
├── variables.tf            # env_active, environment, instance types
├── outputs.tf
├── vpc.tf                  # VPC, private subnets, route tables
├── vpc_endpoints.tf        # S3 gateway + interface endpoints
├── security_groups.tf      # ALB, backend EC2, keycloak EC2, RDS, VPC endpoints
├── alb.tf                  # ALB, 2 target groups, listener rules
├── ec2_backend.tf          # backend instance, IAM profile, user data
├── ec2_keycloak.tf         # keycloak instance, IAM profile, user data
├── rds.tf                  # Postgres, subnet group, snapshot logic
├── dns.tf                  # Route 53 private hosted zone + A records
├── s3.tf                   # frontend bucket + artifacts bucket
├── cloudfront.tf           # distribution, S3 + ALB origins
├── iam.tf                  # EC2 roles, GitHub OIDC
├── ssm.tf                  # parameter store
├── envs/
│   ├── dev.tfvars
│   └── prod.tfvars
└── Makefile
```

---

## 6. On-Demand Environment (Dev Only)

### 6.1 Always On vs. On-Demand

```
  ALWAYS ON                             ON-DEMAND (env_active = true)
  ─────────                             ──────────────────────────────
  ✓ VPC + subnets + route tables        ⏻ EC2 backend
  ✓ Internet gateway (no routes)        ⏻ EC2 keycloak
  ✓ Security groups                     ⏻ RDS Postgres
  ✓ S3 buckets                          ⏻ ALB + target groups
  ✓ CloudFront distribution             ⏻ VPC interface endpoints
  ✓ Route 53 private hosted zone        ⏻ Route 53 A records (for EC2s)
  ✓ IAM roles + policies                ⏻ CloudFront VPC origin
  ✓ SSM parameters
  ✓ S3 gateway VPC endpoint
```

### 6.2 CLI

```bash
make up          # spin up dev (EC2s + RDS + ALB + endpoints)
make down        # tear down dev
make status      # check dev state
make deploy-dev  # trigger deploy.sh on dev backend EC2
```

### 6.3 Env Isolation

- Makefile hardcoded to `ENV=dev`
- Developer IAM scoped to dev state only
- Prod: CI/CD only, manual approval gate

---

## 7. Security Posture

| Layer | Control |
|-------|---------|
| Network | No public subnets. IGW exists but no routes (required by CloudFront VPC origins). VPC endpoints only. |
| Ingress | CloudFront VPC origin → ALB (ENI inside VPC). ALB → EC2s (SG per service). EC2s → RDS (SG). |
| Service isolation | Backend + Keycloak on separate EC2s, separate SGs. |
| Internal DNS | Route 53 private zone. No hardcoded IPs. |
| Access | SSM Session Manager only. No SSH. No bastion. |
| Secrets | SSM Parameter Store (SecureString). |
| TLS | CloudFront terminates public TLS. ALB internal. |
| CI/CD Auth | GitHub OIDC. No long-lived keys. |
| S3 | Private. OAC for CloudFront. |
| IAM | Least privilege. Separate roles per EC2, CI/CD, developer. |

---

## 8. Cost Estimate

| Resource | Spec | ~Monthly (always on) |
|----------|------|---------------------|
| EC2 backend | t3.small | ~$15 |
| EC2 keycloak | t3.small | ~$15 |
| RDS | db.t3.micro (single-AZ) | ~$13 |
| ALB | internal | ~$16 + LCU |
| CloudFront | low traffic | ~$1-5 |
| S3 | frontend + artifacts | < $1 |
| VPC Endpoints | ~4 interface | ~$29 |
| Route 53 | private hosted zone | $0.50 |
| **Per env total** | | **~$90-95** |

| Scenario | Dev | Prod | Total |
|----------|-----|------|-------|
| Dev off, Prod on | ~$1-2 | ~$90-95 | ~$92-97 |
| Dev 8hrs weekdays, Prod on | ~$25-30 | ~$90-95 | ~$115-125 |
| Both always on | ~$90-95 | ~$90-95 | ~$180-190 |

~$15/mo more per env than v2 (the extra EC2). Worth it for service isolation.

---

## 9. What Changed from v2

| Aspect | v2 (single EC2) | v3 (separate EC2s) |
|--------|-----------------|-------------------|
| Compute | 1 EC2 (backend + keycloak) | 2 EC2s (1 backend, 1 keycloak) |
| Failure blast radius | One crash affects both | Isolated — keycloak restart ≠ app downtime |
| Internal routing | localhost | Route 53 private DNS |
| ALB target groups | 1 (port-based routing) | 2 (path → target group) |
| Security groups | Shared SG | Separate SGs per service |
| Terraform files | ec2.tf | ec2_backend.tf + ec2_keycloak.tf + dns.tf |
| Deploy | Single deploy.sh | Independent deploy per service |
| Cost | ~$75-80/env | ~$90-95/env |
| Scaling later | Stuck together | Can scale independently |
