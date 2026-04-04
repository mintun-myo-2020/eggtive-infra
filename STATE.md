# Project State Tracker

## Current Phase: Phase 5 — Terraform: On/Off CLI
## Scope: Dev environment only (prod deferred)

## Task Checklist

### Phase 0 — Planning
- [x] Define architecture (network, compute, storage)
- [x] Define request flow (CloudFront → S3 / ALB → EC2)
- [x] Define CI/CD pipeline (GitHub Actions, OIDC, 3 pipelines)
- [x] Define Terraform file structure
- [x] Define security posture
- [x] Estimate costs
- [x] Review plan with stakeholder (you) ← **APPROVED (v3: separate EC2s, no containers)**

### Phase 1 — Terraform: Networking (shared pattern, deployed per env)
- [x] VPC + private subnets (2 AZs)
- [x] Internet gateway (required by CloudFront VPC origins, no routes)
- [x] Route tables
- [x] VPC endpoints (S3 gateway — always on; interface — on-demand in dev)
- [x] Security groups (ALB, EC2 backend, EC2 keycloak, RDS, VPC endpoints)

### Phase 2 — Terraform: Compute & Data (on-demand in dev, always-on in prod)
- [x] `env_active` variable + conditional `count` pattern (dev only)
- [x] Environment-specific tfvars (`envs/dev.tfvars`)
- [ ] Separate Terraform state per env (S3 backend — deferred until remote state setup)
- [x] EC2 backend instance + IAM profile (SSM + S3 read) — `count` gated in dev
- [x] EC2 keycloak instance + IAM profile (SSM + S3 read) — `count` gated in dev
- [x] User data per EC2: install JDK, download artifact from S3, start systemd
- [x] RDS Postgres (single instance, 2 databases) — `count` gated in dev
- [x] RDS final snapshot on destroy
- [x] S3 artifact bucket (shared across envs: backend.jar, keycloak tarball)
- [x] Route 53 private hosted zone + A records for backend, keycloak, db

### Phase 3 — Terraform: Ingress & CDN
- [x] Internal ALB + 2 target groups (backend, keycloak) + listener rules — `count` gated in dev
- [x] VPC interface endpoints — `count` gated in dev (SSM×3, CW)
- [x] S3 bucket for frontend (per env, private, OAC)
- [x] S3 maintenance page (served when dev env is down)
- [x] CloudFront distribution (S3 origin + conditional ALB VPC origin)
- [x] CloudFront VPC origin for internal ALB connectivity
- [x] Dynamic behaviors in dev: `/api/*`, `/auth/*` → ALB when up, → S3 maintenance when down

### Phase 4 — Terraform: Auth & Secrets
- [x] IAM roles (EC2 with SSM, S3, CloudWatch, SSM params)
- [ ] GitHub OIDC provider (deferred — CI/CD phase)
- [x] SSM Parameter Store entries (DB creds, Keycloak admin, Keycloak URL)
- [ ] Developer IAM: scoped to dev state only (deferred — needs remote state)
- [ ] CI/CD IAM: access to both envs (deferred — prod phase)

### Phase 5 — Terraform: On/Off CLI (dev only) ← **COMPLETED**
- [x] Makefile with `make up`, `make down`, `make status`, `make deploy-dev`
- [x] `terraform validate` passes
- [x] `terraform plan` clean with `env_active=false`
- [x] `terraform plan` clean with `env_active=true`
- [x] Test `make up` against real AWS account
- [x] Test `make down` against real AWS account

### Phase 6 — CI/CD Pipeline ← **WE ARE HERE**
- [x] GitHub Actions: infra pipeline (plan → approve → apply)
- [ ] GitHub Actions: frontend pipeline (build → S3 → invalidate)
- [ ] GitHub Actions: backend pipeline (gradle build → JAR → S3 → SSM deploy)
- [x] OIDC role trust policy for GitHub
- [ ] Manual approval gate for prod deploys
- [x] deploy.sh script on EC2 (download JAR from S3, restart systemd)

### Phase 7 — Validation
- [x] `make up` → dev environment comes online
- [x] Smoke test dev: CloudFront → React loads
- [x] Smoke test dev: `/api/*` proxied to backend
- [x] Smoke test dev: `/auth/*` proxied to Keycloak
- [x] SSM Session Manager access works (dev)
- [x] Keycloak admin login works
- [x] Keycloak realm + clients auto-imported
- [x] Backend JWT validation works (issuer URI match)
- [x] Frontend login flow works end-to-end
- [ ] `make down` → dev environment goes offline (VPC origin deletion workaround needed)
- [ ] Smoke test dev: `/api/*` returns maintenance page when down
- [ ] Prod deploy via CI/CD only
- [ ] Verify `make down` cannot affect prod

## Decisions Log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Separate EC2s for backend and Keycloak | Isolated lifecycles, independent restarts, separate SGs |
| 2 | Route 53 private hosted zone for internal DNS | Services discover each other by name, no hardcoded IPs |
| 3 | Single RDS instance, 2 databases | Cost savings, sufficient for small workload |
| 3 | No public subnets, IGW exists but unused for routing | CloudFront VPC origins require an IGW attached to the VPC (metadata requirement only) |
| 4 | VPC endpoints over NAT gateway | Keeps traffic on AWS backbone per requirement |
| 5 | SSM over SSH | No bastion, no key management, audit trail |
| 6 | GitHub OIDC over access keys | No long-lived credentials in CI/CD |
| 7 | CloudFront proxies /api/* and /auth/* | Single domain, no CORS, React SPA friendly |
| 8 | ALB restricted via CloudFront VPC origin | CloudFront connects to internal ALB via VPC origin ENI, not public internet |
| 9 | On-demand env via `env_active` variable | Only pay for EC2/RDS/ALB when actively using |
| 10 | VPC interface endpoints also on-demand | They're $7.20/ea/mo, only needed when EC2 runs |
| 11 | EC2 user data pulls latest JAR from S3 | `make up` always deploys latest build automatically |
| 12 | RDS final snapshot on destroy | Data persists across spin-up/down cycles |
| 13 | Separate Terraform state per env | Dev and prod fully isolated, can't accidentally cross-affect |
| 14 | `make up/down` hardcoded to dev | Developer CLI cannot touch prod |
| 15 | Prod deploy only via CI/CD + manual approval | Prod changes require PR merge + human approval in GH Actions |
| 16 | Developer IAM scoped to dev state | Even if Makefile is hacked, IAM blocks prod access |
| 17 | S3 artifacts bucket, versioned by SHA | Dev pulls `latest/`, prod pulls specific `builds/<sha>/` promoted through CI/CD |
| 18 | No containers — JVM + systemd | Simpler, fewer VPC endpoints (no ECR), lower cost |
| 19 | deploy.sh per EC2 | Independent deploy scripts, backend and keycloak deploy separately |
| 21 | CloudFront VPC origins for ALB connectivity | CloudFront can't reach internal ALBs via custom_origin_config — VPC origins create an ENI inside the VPC |
| 22 | IGW attached to VPC (no routes) | Required by CloudFront VPC origins, not used for routing — EC2s remain fully private |
| 23 | Keycloak `http-relative-path=/auth` | Keycloak 26.x defaults to `/`, need `/auth` prefix to match ALB path pattern and SSM URL |
| 24 | Keycloak health check on management port 9000 | Keycloak 26.x serves health/metrics on port 9000, not the main HTTP port |
| 25 | `health-enabled=true` in keycloak.conf | Must be set at build time (`kc.sh build`) for health endpoints to exist at runtime |
| 26 | Prometheus scrapes `/auth/metrics` on port 9000 | `http-relative-path=/auth` is inherited by the management interface |
| 27 | Keycloak `hostname=https://<domain>/auth` + `http-enabled=true` | Edge TLS termination mode. `hostname` with https scheme forces HTTPS URLs; `http-enabled=true` allows HTTP from ALB. Do NOT use `proxy-headers=xforwarded` (ALB overwrites X-Forwarded-Proto to http). Config saved to staging path to survive tarball extraction. |
| 28 | Realm import at boot from S3 | `realm-export.json` for realm/clients/roles, `realm-export-dev-users.json` for dev test users only |
| 29 | `--override false` on realm import | Preserves existing realm data on subsequent boots, only imports on fresh DB |
| 30 | Self-healing EC2s via systemd ExecStartPre | S3 downloads + SSM reads in ExecStartPre, retried every 30s by systemd until artifacts arrive |
| 31 | EC2 `depends_on` RDS + SSM + VPC endpoints | Terraform creates dependencies before EC2s, reducing race conditions. Self-healing is safety net |
| 32 | Bedrock VPC endpoint + IAM policy | Backend uses Bedrock for extraction + LLM. Endpoint needed since EC2s have no internet access |
| 33 | Auto-generated Keycloak client secret in SSM | Terraform generates random secret, stores in SSM. Setup script syncs it to Keycloak's spm-backend client via kcadm |
| 34 | Backend KEYCLOAK_ISSUER_URI uses public URL | Must match token's `iss` claim (`https://<domain>/auth/realms/spm`). JWK_SET_URI uses internal URL for actual key fetching |
| 35 | 3-phase `make up` | Phase 1: base infra (S3 buckets). Phase 2: upload artifacts. Phase 3: compute (EC2s find artifacts in S3 on boot) |
| 36 | Domain convention: `<env>.spm.eggtive.com` | Dev: `dev.spm.eggtive.com`. Prod customers: `<org>.spm.eggtive.com` |

## Open Questions

- [x] Custom domain or CloudFront default domain? → Custom: `dev.spm.eggtive.com` (dev), `<org>.spm.eggtive.com` (prod)
- [x] Which backend runtime/framework? → Spring Boot (JDK 25) via systemd
- [x] Keycloak version preference? → 26.1.0
- [x] Do we need multi-AZ RDS or is single-AZ fine for now? → Single-AZ for dev, multi-AZ for prod
- [x] Terraform state backend — new S3 bucket + DynamoDB, or existing? → New: `eggtive-spm-terraform-state` + `terraform-locks`
- [x] GitHub repo name (for OIDC trust policy)? → `mintun-myo-2020/spm`
- [x] RDS data strategy? → Fresh DB on `make up`, realm imported from S3 export
