# Platform Infrastructure

Shared infrastructure for all apps. Manages VPC, compute (EC2), database (RDS), CDN (CloudFront), monitoring (Prometheus + Grafana), and IAM for CI/CD.

App teams deploy through their own GitHub Actions pipelines — this repo controls who gets access.

## Onboarding a New App

1. Open a PR adding your app to `infra/envs/dev.tfvars`:

```hcl
trusted_apps = {
  spm     = { github_repo = "spm" }
  billing = { github_repo = "billing-service" }  # ← add your app
}
```

2. CI runs `terraform plan` — the PR comment shows the new IAM role being created.

3. Infra owner reviews and merges.

4. CI applies. Your app gets:
   - An IAM role scoped to your GitHub repo (OIDC, no long-lived credentials)
   - S3 artifacts access under `s3://<artifacts-bucket>/<app-name>/*`
   - S3 frontend bucket access
   - CloudFront cache invalidation
   - SSM SendCommand for EC2 deploys
   - SSM parameter read for CI/CD config

5. Get your role ARN from Terraform output:
   ```
   terraform output app_deploy_role_arns
   ```

6. In your app repo, configure GitHub Actions to assume the role:
   ```yaml
   permissions:
     id-token: write
     contents: read

   steps:
     - uses: aws-actions/configure-aws-credentials@v4
       with:
         role-to-assume: <your-role-arn>
         aws-region: ap-southeast-1
   ```

7. Upload your build artifact to your S3 prefix:
   ```
   aws s3 cp build/app.jar s3://<artifacts-bucket>/<app-name>/app.jar
   ```

## Offboarding an App

Remove the entry from `trusted_apps` and merge. The role and all its policies are destroyed on the next apply — access is revoked immediately.

## Repo Structure

```
infra/
  envs/           # Per-environment config (dev.tfvars, prod.tfvars)
  templates/      # EC2 userdata scripts
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
