# Platform Infrastructure

Shared infrastructure for all apps. Manages VPC, compute (EC2), database (RDS), CDN (CloudFront), monitoring (Prometheus + Grafana), and IAM for CI/CD.

App teams deploy through their own GitHub Actions pipelines — this repo controls who gets access.

## Onboarding a New App

### Step 1: CI/CD Access

Open a PR adding your app to `trusted_apps` in `infra/envs/dev.tfvars`:

```hcl
trusted_apps = {
  spm     = { github_repo = "spm" }
  billing = { github_repo = "billing-service" }  # ← add your app
}
```

This creates an IAM role scoped to your GitHub repo with:
- S3 artifacts access under `s3://<artifacts-bucket>/<app-name>/*`
- S3 frontend bucket access
- CloudFront cache invalidation
- SSM SendCommand for EC2 deploys
- SSM parameter read for CI/CD config

### Step 2: Compute (optional)

If your app needs an EC2 instance, add it to `app_workloads`:

```hcl
app_workloads = {
  billing = {
    instance_type = "t3.small"
    runtime       = "go"            # java21, java25, go, python3, node20
    artifact      = "billing"       # filename in S3 under <app-name>/ prefix
    port          = 8080            # app listen port
    # metrics_path = "/metrics"     # optional, defaults to /metrics
    # health_path  = "/health"      # optional, defaults to /health
  }
}
```

This creates:
- EC2 instance with your runtime pre-installed
- Security group allowing your port from VPC
- CloudWatch log group at `/<project>/<env>/<app-name>`
- Prometheus auto-discovery via instance tags (scraped automatically)
- systemd service with auto-restart and SSM-based config

### Supported Runtimes

| Runtime | Installed | Run command |
|---------|-----------|-------------|
| `java21` | Amazon Corretto 21 | `java -jar /opt/app/artifact` |
| `java25` | Amazon Corretto 25 | `java -jar /opt/app/artifact` |
| `go` | Nothing (static binary) | `/opt/app/artifact` |
| `python3` | Python 3 + pip | `python3 /opt/app/artifact` |
| `node20` | Node.js 20 | `node /opt/app/artifact` |

### Step 3: Configuration (optional)

If your app needs runtime config (DB connections, API keys, etc.), infra owner stores them in SSM Parameter Store under:

```
/<project-name>/<environment>/<app-name>/<key>
```

Examples:
```
/eggtive-spm/dev/billing/db/url
/eggtive-spm/dev/billing/db/password
/eggtive-spm/dev/billing/api-key
```

The instance reads all params under the app's prefix at startup and converts paths to env vars:
- `.../billing/db/url` → `DB_URL`
- `.../billing/api-key` → `API_KEY`

If no params exist under the prefix, the app starts with no injected env vars.

App teams provide the values they need; infra owner stores them via:
```bash
aws ssm put-parameter --name "/<project>/<env>/<app>/db/url" \
  --value "jdbc:postgresql://..." --type SecureString
```

### Step 4: Configure Your CI

Set the role ARN as a secret in your app repo:
```
terraform output app_deploy_role_arns
# → { "billing" = "arn:aws:iam::123456:role/eggtive-spm-dev-billing-deploy" }
```

Then your entire deploy workflow:

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

      - name: Build
        run: go build -o billing ./cmd/server

      - name: Deploy
        uses: mintun-myo-2020/spm-infra/.github/actions/deploy@main
        with:
          app-name: billing
          artifact-path: billing
          environment: dev
          role-arn: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
```

The reusable action handles: OIDC auth → S3 upload → SSM deploy trigger → wait for success/failure.

**Inputs:**

| Input | Required | Description |
|-------|----------|-------------|
| `app-name` | yes | Must match your `app_workloads` key |
| `artifact-path` | yes | Path to your build output |
| `environment` | yes | `dev` or `prod` |
| `role-arn` | yes | From `terraform output app_deploy_role_arns` |
| `artifact-name` | no | S3 filename (defaults to `app-name`) |
| `aws-region` | no | Defaults to `ap-southeast-1` |

## Offboarding an App

Remove the entry from `trusted_apps` (and `app_workloads` if applicable) and merge. The role, policies, EC2 instance, and security group are all destroyed on next apply. Access is revoked immediately.

## Monitoring

Prometheus auto-discovers all EC2 instances with `MetricsPort` and `MetricsPath` tags using EC2 service discovery. No config changes needed — just tag your instance and it gets scraped.

Access dashboards:
```
make grafana-ui       # http://localhost:3000
make prometheus-ui    # http://localhost:9090
```

## Repo Structure

```
infra/
  envs/           # Per-environment config (dev.tfvars, prod.tfvars)
  templates/      # EC2 userdata scripts (app-specific + generic)
  exports/        # Keycloak realm exports
  dist/           # Local binary artifacts (gitignored, uploaded to S3)
  Makefile        # Ops toolkit (bootstrap, up/down, ssh, port-forward)
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

## CI/CD

Push to `main` triggers:
1. `terraform plan` for dev and prod
2. Auto-apply to dev (with environment protection)
3. Manual approval → apply to prod

PRs get a plan comment showing exactly what changes.
