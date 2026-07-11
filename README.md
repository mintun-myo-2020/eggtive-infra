# Platform Infrastructure

Shared infrastructure for all apps. Manages VPC, compute (EC2 + ECS Fargate), database (RDS), CDN (CloudFront), monitoring (Prometheus + Grafana), and IAM for CI/CD.

App teams deploy through their own GitHub Actions pipelines — this repo controls who gets access.

## Onboarding a New App

### Step 1: CI/CD Access

Open a PR adding your app to `trusted_apps` in `infra/envs/dev.tfvars`:

```hcl
trusted_apps = {
  spm    = { github_repo = "spm" }
  social = { github_repo = "social" }  # ← add your app
}
```

This creates an IAM role scoped to your GitHub repo with:
- S3 artifacts access under `s3://<artifacts-bucket>/<app-name>/*`
- S3 frontend bucket access (shared + per-app if configured)
- CloudFront cache invalidation
- SSM SendCommand for EC2 deploys
- SSM parameter read for CI/CD config
- ECR push + ECS deploy (if `container_workloads` is configured)

### Step 2: Compute

**Option A: EC2 instance** — add to `app_workloads`:

```hcl
app_workloads = {
  billing = {
    instance_type = "t3.small"
    runtime       = "go"            # java21, java25, go, python3, node20
    artifact      = "billing"       # filename in S3 under <app-name>/ prefix
    port          = 8080
  }
}
```

**Option B: ECS Fargate container** — add to `container_workloads`:

```hcl
container_workloads = {
  social = {
    cpu     = 256        # 0.25 vCPU
    memory  = 512        # MB
    port    = 8080
    runtime = "go"       # java21, java25, go, python3, node20

    # Optional: dedicated database
    database = {
      instance_class = "db.t3.micro"
      db_name        = "socialdb"
    }

    # Optional: dedicated frontend (S3 + CloudFront + cert + DNS)
    frontend = {
      subdomain = "social"  # → dev.social.eggtive.com
    }
  }
}
```

### What gets created per container workload

| Layer | Resources |
|-------|-----------|
| Compute | ECR repo, ECS task definition, Fargate service, security group |
| Routing | ALB target group, listener rule (`/api/<app-name>/*`) |
| Logs | CloudWatch log group at `/<project>/<env>/ecs/<app-name>` |
| Database (if configured) | RDS instance, security group, SSM params (`DB_URL`, `DB_USERNAME`, `DB_PASSWORD`) |
| Frontend (if configured) | S3 bucket, CloudFront distribution, ACM cert, DNS record (`<env>.<subdomain>.<root-domain>`) |
| CI/CD | SSM params for bucket name + CloudFront distribution ID |

### URL Convention

All app frontends follow `<env>.<app-name>.<root-domain>`:

| App | Dev | Prod |
|-----|-----|------|
| SPM | `dev.spm.eggtive.com` | `prod.spm.eggtive.com` |
| Social | `dev.social.eggtive.com` | `prod.social.eggtive.com` |

### API Routing

Each app's API is served under `/api/<app-name>/*` on its own CloudFront distribution:

```
Browser → dev.social.eggtive.com/api/social/posts
       → CloudFront (/api/* behavior)
       → ALB
       → listener rule /api/social/* (priority 50)
       → ECS task on port 8080
```

Your app should use `http.StripPrefix("/api/<app-name>", mux)` so handlers receive clean paths like `/posts`.

### DB URL Format

The platform auto-generates DB credentials and stores them in SSM. The URL format depends on runtime:

| Runtime | DB_URL format |
|---------|---------------|
| `java21` / `java25` | `jdbc:postgresql://host:5432/dbname` |
| `go` / `node20` / `python3` | `postgres://user:pass@host:5432/dbname` (standard DSN) |

For ECS apps with a `database` block, credentials are injected as container env vars automatically — no SDK calls needed:
- `DB_URL` — full connection string
- `DB_USERNAME` — database user
- `DB_PASSWORD` — auto-generated password

### Supported Runtimes

| Runtime | EC2 (installed) | ECS (OTel auto-instrumentation) |
|---------|-----------------|----------------------------------|
| `java21` | Amazon Corretto 21 | `JAVA_TOOL_OPTIONS=-javaagent:/otel/...` |
| `java25` | Amazon Corretto 25 | Same as java21 |
| `go` | Nothing (static binary) | None (use OTel SDK manually) |
| `python3` | Python 3 + pip | None (manual SDK) |
| `node20` | Node.js 20 | `NODE_OPTIONS=--require @opentelemetry/...` |

### Step 3: Configure Your CI

Get the deploy role ARN:
```bash
terraform output app_deploy_role_arns
# → { "social" = "arn:aws:iam::...:role/eggtive-spm-dev-social-deploy" }
```

Set it as a secret in your app repo:
```bash
gh secret set AWS_DEPLOY_ROLE_ARN --repo <org>/<app-repo> --body "<role-arn>"
```

**Container deploy workflow:**

```yaml
name: Deploy

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        uses: mintun-myo-2020/eggtive-infra/.github/actions/deploy-container@main
        with:
          app-name: social
          environment: dev
          role-arn: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
```

The action handles: OIDC auth → ECR login → docker build → push → ECS force new deployment → wait for stabilization.

**Frontend deploy workflow:**

Requires GitHub environment variables set in the app repo:
- `PROJECT_NAME` = `eggtive-spm`
- `ENVIRONMENT` = `dev`

SSM param names for per-app frontends use the pattern:
```
/<project>/<env>/cicd/<app-name>-frontend-bucket
/<project>/<env>/cicd/<app-name>-cloudfront-distribution-id
```

### Step 4: Auth (optional)

All apps share the platform's Keycloak instance. Each app's CloudFront routes `/auth/*` to the ALB → Keycloak automatically.

To use auth:
1. Create a realm or client in Keycloak for your app
2. Store the client secret in SSM: `/<project>/<env>/<app>/keycloak/client-secret`
3. Your app reads it from the `KEYCLOAK_CLIENT_SECRET` env var (or SSM directly)

If your app doesn't need auth, just don't read the Keycloak params — no config needed.

## Offboarding an App

Remove the entry from `trusted_apps` (and `app_workloads`/`container_workloads` if applicable) and merge. The role, policies, EC2/ECS resources, databases, frontend buckets, and security groups are all destroyed on next apply. Access is revoked immediately.

## Monitoring

Prometheus auto-discovers all EC2 instances with `MetricsPort` and `MetricsPath` tags using EC2 service discovery. No config changes needed — just tag your instance and it gets scraped.

For ECS apps, expose a `/metrics` endpoint and Prometheus scrapes via the internal DNS.

Access dashboards:
```
make grafana-ui       # http://localhost:3000
make prometheus-ui    # http://localhost:9090
```

## Repo Structure

```
infra/
  envs/           # Per-environment config (dev.tfvars, prod.tfvars)
  templates/      # EC2 userdata scripts (SPM backend, Keycloak, Prometheus)
  exports/        # Keycloak realm exports
  dist/           # Local binary artifacts (gitignored, uploaded to S3)
  Makefile        # Ops toolkit (bootstrap, up/down, ssh, port-forward)
  ecs.tf          # ECS Fargate cluster, services, task definitions
  rds_apps.tf     # Per-app RDS instances
  cdn_apps.tf     # Per-app S3 + CloudFront + ACM + DNS
  ec2_apps.tf     # Generic EC2 app workloads
```

## Ops Commands (Makefile)

| Command | What it does |
|---------|-------------|
| `make bootstrap` | One-time: create state bucket + DynamoDB lock table |
| `make up` | Bring environment up (phased: base → artifacts → compute) |
| `make down` | Tear down compute (preserves S3/CloudFront) |
| `make update` | Apply infra changes to a running environment |
| `make ssh-backend` | SSM session to backend instance |
| `make ssh-keycloak` | SSM session to Keycloak instance |
| `make ssh-prometheus` | SSM session to Prometheus instance |
| `make grafana-ui` | Port-forward Grafana to localhost:3000 |
| `make prometheus-ui` | Port-forward Prometheus to localhost:9090 |
| `make seed-artifacts` | Upload Keycloak/Prometheus/Grafana binaries to S3 |
| `make taint-backend` | Force rebuild backend EC2 on next apply |

### Why `make down` is manual (not CI)

CloudFront refuses to delete a VPC origin while it's still associated with a distribution. Terraform tries to destroy both simultaneously and fails with `CannotDeleteEntityWhileInUse`.

`make down` handles this with a multi-step workaround:

1. **CLI:** Patch CloudFront config to remove the ALB origin and switch `/api/*` + `/auth/*` behaviors to the S3 maintenance page
2. **CLI:** Wait for CloudFront deployment to finish
3. **CLI:** Delete the now-orphaned VPC origin
4. **TF:** Remove the VPC origin from Terraform state (already deleted by CLI)
5. **TF:** `terraform apply env_active=false` destroys remaining compute (EC2, RDS, ALB, ECS, VPC endpoints)

On `make up`, Terraform recreates the VPC origin + ALB origin from scratch.

## Environment State (`env_active`)

Compute resources (EC2, RDS, ALB, ECS services, VPC endpoints) are controlled by `env_active`. This is managed via **GitHub environment variables**, not in code.

**Setup (one-time):**

Repo → Settings → Environments → `dev` → Variables:
- `ENV_ACTIVE` = `true`

**How it works:**
- CI reads `ENV_ACTIVE` from the GitHub environment and passes it as `-var="env_active=..."` to Terraform
- Locally, `make up`/`make down` override with `-var="env_active=true/false"`
- The variable is NOT in `dev.tfvars` — it lives in GitHub so the env state is decoupled from code

**What's always on (regardless of `env_active`):**
- S3 buckets, CloudFront distributions, ACM certs, DNS records
- ECR repositories, IAM roles, SSM parameters
- VPC, subnets, route tables, S3 gateway endpoint

**What's on-demand (only when `env_active=true`):**
- EC2 instances (backend, Keycloak, Prometheus)
- RDS instances (shared + per-app)
- ECS cluster, services, task definitions
- ALB, target groups, listener rules
- Interface VPC endpoints
- Security groups for compute

**Toggling compute:**

```bash
# Bring down (for cost savings overnight, etc.)
gh variable set ENV_ACTIVE --env dev --body "false"
make down   # handles the VPC origin workaround locally

# Bring back up
gh variable set ENV_ACTIVE --env dev --body "true"
make up     # or push any infra change — CI will apply with env_active=true
```

## CI/CD

Push to `main` triggers:
1. `terraform plan` for dev and prod
2. Auto-apply to dev (with environment protection)
3. Manual approval → apply to prod

PRs get a plan comment showing exactly what changes.
