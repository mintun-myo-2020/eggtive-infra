# Production Deployment Guide — Eggtive SPM

How to go from dev to serving real customers in production.

---

## Dev vs Prod — What Changes

| Aspect | Dev | Prod |
|--------|-----|------|
| Lifecycle | `make up` / `make down` | Always on, CI/CD only |
| `env_active` | toggled | always `true` |
| RDS | single-AZ, destroyed on `make down` | multi-AZ, never destroyed |
| RDS snapshots | final snapshot on destroy | automated daily backups |
| Keycloak realm | manual setup, persists in DB | automated import from realm JSON in S3 |
| Deploys | `make deploy-dev` or CI | CI/CD with manual approval gate |
| Domain | `dev.spm.eggtive.com` | `<org>.spm.eggtive.com` |
| Terraform state | `dev/terraform.tfstate` | `prod/terraform.tfstate` (separate) |
| Who can touch it | developer (Makefile + IAM) | CI/CD only (GitHub Actions + OIDC) |

---

## The Full Flow — First Prod Deploy

### Step 1: Keycloak Realm Export (one-time, from dev)

Once you've configured the `spm` realm, clients, roles, etc. in dev, export it:

```bash
# SSM into dev Keycloak
aws ssm start-session --target <dev-keycloak-instance-id>

# Export the realm (excludes users by default)
/opt/keycloak/bin/kc.sh export \
  --dir /tmp/export \
  --realm spm \
  --users skip

# Copy the export to your local machine
# (from your laptop, not the EC2)
aws s3 cp s3://eggtive-spm-artifacts/keycloak/spm-realm.json - < /tmp/export/spm-realm.json
```

Or export from the admin console: Realm Settings → Action → Partial Export.

Upload the realm JSON to S3:
```bash
aws s3 cp spm-realm.json s3://eggtive-spm-artifacts/keycloak/spm-realm.json
```

### Step 2: Update Keycloak Userdata for Auto-Import

The userdata script should import the realm on first boot (when the DB is fresh).
This is already handled if you add the import step — Keycloak skips import if
the realm already exists in the database.

Add to `keycloak_userdata.sh` after the build step:

```bash
# Import realm if export file exists in S3
if aws s3 cp "s3://${s3_artifact_bucket}/keycloak/spm-realm.json" /tmp/spm-realm.json; then
  sudo -u keycloak /opt/keycloak/bin/kc.sh import --file /tmp/spm-realm.json
  rm /tmp/spm-realm.json
  echo "Realm imported"
fi
```

This is idempotent — if the realm already exists (from a previous boot or
snapshot restore), Keycloak skips the import.

### Step 3: Create Prod tfvars

```hcl
# infra/envs/prod.tfvars
environment            = "acme"
env_active             = true
custom_domain          = "acme.spm.eggtive.com"
domain_name            = "internal.acme.eggtive-spm"
db_instance_class    = "db.t3.small" # more RAM for prod
backend_instance_type = "t3.small"
keycloak_instance_type = "t3.small"
```

### Step 4: Separate Terraform State

Prod uses a different state key so dev and prod are fully isolated:

```hcl
# For prod, the backend config uses key = "prod/terraform.tfstate"
# You'll need a separate terraform init or use workspaces
```

Option A — separate directories:
```
infra/
├── envs/
│   ├── dev.tfvars
│   └── prod.tfvars
```
Run with: `terraform apply -var-file=envs/prod.tfvars`
State key configured per environment in the backend block or via `-backend-config`.

Option B — Terraform workspaces (simpler):
```bash
terraform workspace new prod
terraform apply -var-file=envs/prod.tfvars
```

### Step 5: CI/CD Pipeline (GitHub Actions)

```
push to main
    │
    ├── frontend/** changed?
    │   └── npm build → S3 sync (both envs) → CloudFront invalidate
    │
    ├── backend/** changed?
    │   └── gradle build → JAR → S3
    │       ├── dev: auto-deploy (SSM send-command)
    │       └── prod: manual approval gate → SSM send-command
    │
    └── infra/** changed?
        └── terraform plan → review → approve → apply
            (separate jobs for dev and prod)
```

The manual approval gate is critical — no code reaches prod without a human
clicking "Approve" in the GitHub Actions UI.

### Step 6: DNS + Certificate

Prod needs its own:
- ACM certificate for `app.eggtive.com` (or whatever domain)
- Route 53 alias record pointing to the prod CloudFront distribution
- These are handled by the same Terraform code with different `custom_domain` variable

### Step 7: First Apply

```bash
# From CI/CD (not Makefile — Makefile is dev-only)
terraform init -backend-config="key=prod/terraform.tfstate"
terraform apply -var-file=envs/prod.tfvars
```

This creates the full stack: VPC, IGW, subnets, ALB, EC2s, RDS, CloudFront,
VPC origin, etc. Keycloak boots, imports the realm from S3, and is ready.

---

## Ongoing Prod Operations

### Code Deploys

```
Developer pushes to main
  → CI builds JAR
  → CI uploads to S3
  → CI triggers SSM send-command (targets tag: Service=backend, Environment=prod)
  → EC2 runs deploy.sh: download JAR, restart systemd
```

Zero-downtime isn't built in yet (single EC2). For that you'd need:
- A second EC2 behind the ALB (blue/green or rolling)
- Or ECS/Fargate (future migration path)

### Keycloak Updates

1. Upload new Keycloak tarball to S3
2. Taint the Keycloak EC2: `terraform taint aws_instance.keycloak[0]`
3. Apply — new EC2 boots, downloads new Keycloak, imports realm, starts
4. Or: SSM in, download new tarball, rebuild, restart (no Terraform needed)

### Database

- Prod RDS should have `multi_az = true` for failover
- Automated backups enabled (7-day retention minimum)
- `skip_final_snapshot = false` (already set)
- Consider `deletion_protection = true` to prevent accidental destroy

### Monitoring

Prometheus is already scraping backend and Keycloak metrics.
For prod, add:
- CloudWatch alarms on ALB 5xx rate, target health, response time
- RDS alarms on CPU, connections, storage
- SNS notifications to your email/Slack

### Secrets Rotation

- RDS password: rotate via SSM Parameter Store update + EC2 restart
- Keycloak admin password: same pattern
- No secrets in git, no secrets in CI/CD env vars

---

## Prod Checklist

```
[ ] Keycloak realm exported from dev and uploaded to S3
[ ] Keycloak userdata updated with auto-import step
[ ] prod.tfvars created with prod-specific values
[ ] Separate Terraform state backend configured for prod
[ ] CI/CD pipeline with manual approval gate for prod
[ ] ACM certificate for prod domain
[ ] Route 53 records for prod domain
[ ] RDS multi_az = true
[ ] RDS deletion_protection = true
[ ] CloudWatch alarms configured
[ ] First terraform apply for prod
[ ] Smoke test: frontend loads
[ ] Smoke test: /auth/* reaches Keycloak, realm exists
[ ] Smoke test: /api/* reaches backend
[ ] Smoke test: login flow works end-to-end
[ ] Developer IAM cannot touch prod state
[ ] Makefile cannot touch prod
```
