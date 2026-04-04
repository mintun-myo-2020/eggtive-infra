# CI/CD Process — Eggtive SPM

How infrastructure and application deployments work across dev and prod.

---

## Environment Isolation

| | Dev | Prod |
|---|-----|------|
| AWS Account | Account A | Account B |
| S3 buckets | `eggtive-spm-artifacts` (Account A) | `eggtive-spm-artifacts` (Account B) |
| Terraform state | `s3://eggtive-spm-terraform-state/dev/` | `s3://eggtive-spm-terraform-state/prod/` (Account B) |
| OIDC role | `eggtive-spm-dev-github-actions` | `eggtive-spm-prod-github-actions` |
| Who can deploy | Developer laptop (`make up`) + CI | CI/CD only (with manual approval) |
| `env_active` | Toggled (`make up`/`make down`) | Always `true` |
| Keycloak users | Seeded from `realm-export-dev-users.json` | Created manually by admin |

Nothing is shared between accounts. Each account has its own VPC, S3 buckets,
RDS, EC2s, CloudFront, state bucket, and IAM roles.

---

## Dev — Local Workflow

Dev is controlled from your laptop via the Makefile.

### Fresh Install (from scratch)

```bash
cd infra
make init                    # terraform init (one-time)
make up                      # 3-phase deploy:
                             #   1. terraform apply env_active=false (creates S3, VPC, CloudFront, etc.)
                             #   2. uploads tarballs + realm exports to S3
                             #   3. terraform apply env_active=true (creates EC2s, RDS, ALB)
                             #   EC2s boot → pull artifacts from S3 → start services
```

Prerequisites in `infra/dist/` (gitignored, download once):
- `keycloak-26.1.0.tar.gz` — from Keycloak GitHub releases
- `prometheus-3.5.1.linux-amd64.tar.gz` — from Prometheus GitHub releases

Prerequisites in `infra/exports/` (committed to git):
- `realm-export.json` — realm, clients, roles
- `realm-export-dev-users.json` — test users (dev only)

### Daily Usage

```bash
make up                      # spin up (skips phase 1 if buckets exist, re-uploads artifacts)
make down                    # tear down (EC2s, RDS, ALB destroyed; S3, CloudFront stay)
make deploy-dev              # deploy latest backend JAR to running EC2
make taint-keycloak && make up  # recreate Keycloak EC2 with fresh userdata
make ssh-keycloak            # SSM shell into Keycloak
make prometheus-ui           # port-forward Prometheus UI to localhost:9090
```

### Infra Changes via CI

When you push infra changes to GitHub:

```
PR opened (infra/** changed)
  → CI: terraform fmt -check
  → CI: terraform plan
  → CI: posts plan as PR comment
  → You review the plan

PR merged to main
  → CI: terraform plan
  → CI: uploads realm exports to S3
  → CI: waits for approval (GitHub environment: dev)
  → CI: terraform apply
```

This is for incremental changes (new SG rule, updated userdata template, etc.),
not for bootstrapping. Bootstrap is always `make up` from your laptop.

---

## Prod — CI/CD Only

Prod lives in a separate AWS account. No one runs `make` against prod.
All changes go through CI/CD with manual approval.

### First-Time Bootstrap

This is a one-time process to set up the prod account:

**1. Prep the prod AWS account:**
- Create the Terraform state bucket + DynamoDB lock table (same as dev `make bootstrap`, but in prod account)
- Create the GitHub OIDC provider + IAM role for CI/CD
- Store the prod OIDC role ARN as a GitHub secret (`AWS_PROD_CICD_ROLE_ARN`)

**2. Create `envs/prod.tfvars`:**
```hcl
environment            = "acme"
env_active             = true
custom_domain          = "acme.spm.eggtive.com"
domain_name            = "internal.acme.eggtive-spm"
db_instance_class      = "db.t3.small"
backend_instance_type  = "t3.small"
keycloak_instance_type = "t3.small"
```

**3. Create the GitHub environment:**
- Repo Settings → Environments → create `prod`
- Enable "Required reviewers" → add yourself
- This creates the manual approval gate

**4. First deploy via CI:**
Push the prod tfvars + workflow changes to main. The prod CI job:

```
Phase 1: terraform apply env_active=false
  → creates S3 buckets, VPC, IGW, CloudFront, IAM, ACM cert, etc.

Phase 2: download + upload artifacts
  → downloads Keycloak tarball from GitHub releases (version pinned in workflow)
  → downloads Prometheus tarball from GitHub releases (version pinned in workflow)
  → uploads both to prod S3 artifacts bucket
  → uploads realm-export.json from git to prod S3

Phase 3: terraform apply env_active=true
  → creates EC2s, RDS, ALB, VPC endpoints, DNS records, CloudFront VPC origin
  → EC2s boot, pull artifacts from S3, start services
  → Keycloak imports realm (fresh DB, so import runs)
```

**5. Post-bootstrap:**
- Log into Keycloak admin console (`https://app.eggtive.com/auth/admin/`)
- Create real users (admin does this, not automated)
- Verify the full flow works

### Ongoing Prod Deploys

**Infra changes:**
```
Push to main (infra/** changed)
  → CI: terraform plan (prod)
  → CI: posts plan to PR
  → Merge
  → CI: waits for manual approval
  → CI: terraform apply
```

**App deploys (from the app repo):**
```
Push to main (backend/** changed)
  → CI: gradle build → JAR
  → CI: upload JAR to prod S3
  → CI: waits for manual approval
  → CI: SSM send-command → prod EC2 runs deploy.sh
```

**Keycloak version upgrade:**
1. Update the Keycloak version in the CI workflow
2. Push to main → CI downloads new tarball, uploads to S3
3. Taint the Keycloak EC2 in Terraform (or add a workflow step)
4. CI applies → new EC2 boots with new Keycloak version
5. Realm data preserved in RDS (import skips with `--override false`)

---

## Artifact Versions

Pinned in the CI workflow, not in the Makefile:

```yaml
env:
  KEYCLOAK_VERSION: "26.1.0"
  PROMETHEUS_VERSION: "3.5.1"
```

CI downloads from official release URLs:
- `https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz`
- `https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz`

For dev, you download these once into `infra/dist/` and `make up` uploads them.
For prod, CI downloads fresh every time (or caches them).

---

## Realm Export Lifecycle

```
Developer makes realm changes in dev admin console
  → exports realm JSON from admin console
  → saves to infra/exports/realm-export.json
  → commits + pushes to git
  → CI uploads to S3 (both dev and prod)
  → next fresh Keycloak boot imports it automatically
  → running Keycloak instances are NOT affected (--override false)
```

The export files in git are for bootstrapping fresh environments.
Running environments get realm changes via the admin console directly.

---

## What Triggers What

| Event | Dev | Prod |
|-------|-----|------|
| `make up` | Full 3-phase deploy | N/A (no make for prod) |
| `make down` | Tears down compute | N/A |
| Push to `infra/**` on main | CI: plan → approve → apply | CI: plan → approve → apply |
| Push to `backend/**` on main | CI: build → deploy (auto) | CI: build → approve → deploy |
| Push to `frontend/**` on main | CI: build → S3 sync → invalidate | CI: build → S3 sync → invalidate |
| Push to `infra/exports/**` | CI: uploads to S3 | CI: uploads to S3 |
| Keycloak realm change | Admin console (live) | Admin console (live) |
