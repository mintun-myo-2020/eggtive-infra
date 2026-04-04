# Troubleshooting Guide — Eggtive SPM

Issues we hit during setup and how they were resolved.
Read this before debugging — your problem is probably here.

---

## CloudFront / ALB / Networking

### "Failed to contact the origin" from CloudFront

**Symptom:** Browser shows CloudFront error page with "Failed to contact the origin" and a Request ID.

**Cause:** CloudFront cannot reach the internal ALB. A regular `custom_origin_config` cannot resolve private IPs. CloudFront needs VPC Origins to connect to internal ALBs.

**Fix:** Use `aws_cloudfront_vpc_origin` resource with `vpc_origin_config` in the distribution origin block. Also requires an internet gateway attached to the VPC (AWS metadata requirement — no routes needed).

### 504 Gateway Timeout from CloudFront

**Symptom:** CloudFront returns 504 after the VPC origin is set up.

**Cause:** The ALB security group wasn't allowing traffic from CloudFront. Even with VPC origins, the ALB SG must allow the CloudFront managed prefix list (`com.amazonaws.global.cloudfront.origin-facing`). Using VPC CIDR alone is not sufficient.

**Fix:** ALB SG ingress uses `prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]`.

### VPC Origin deletion fails on `make down` or `terraform destroy`

**Symptom:** `CannotDeleteEntityWhileInUse: The specified VPC origin is currently associated with one or more distributions`

**Cause:** Terraform tries to delete the VPC origin before CloudFront finishes disassociating it. CloudFront distribution updates are async. This is a known AWS Terraform provider limitation.

**Workaround:**
1. CloudFront console → Distributions → disable the distribution → wait for "Deployed"
2. Delete the distribution
3. CloudFront → VPC origins → delete the orphaned VPC origin
4. `terraform state rm 'aws_cloudfront_vpc_origin.alb[0]'`
5. Run `make down` or `terraform destroy` again

---

## Keycloak

### "Key material not provided to setup HTTPS"

**Symptom:** Keycloak crashes on startup with this error, systemd retries endlessly.

**Cause:** `hostname=https://domain/auth` in `keycloak.conf` tells Keycloak to use HTTPS URLs, but without `http-enabled=true` taking effect, Keycloak demands TLS certificates.

**Fix:** Ensure both are set in `keycloak.conf`:
```
hostname=https://spm.eggtive.com/auth
http-enabled=true
```
Both must be present at `kc.sh build` time. Also: the config file must be saved to a staging location (`/opt/deploy/keycloak.conf`) because the Keycloak tarball extraction overwrites `conf/keycloak.conf` with defaults.

### Mixed Content errors (http:// URLs in browser)

**Symptom:** Browser blocks resources because Keycloak generates `http://` URLs on an `https://` page.

**Cause:** Keycloak doesn't know it's behind a TLS-terminating proxy. The ALB connects over HTTP, so Keycloak thinks the scheme is HTTP.

**What doesn't work:**
- `proxy-headers=xforwarded` — the ALB overwrites `X-Forwarded-Proto` to `http` (based on its listener protocol), so Keycloak always sees HTTP.
- `hostname-strict=false` alone — Keycloak uses the request's scheme/host, which is HTTP.

**What works:** `hostname=https://<domain>/auth` — forces HTTPS in all generated URLs regardless of the actual request scheme. Combined with `http-enabled=true` so Keycloak still accepts HTTP connections from the ALB.

### Keycloak admin user not created

**Symptom:** `user_not_found` when trying to login as admin, even though the bootstrap log says "Admin user created successfully."

**Cause:** `KEYCLOAK_ADMIN` env vars only create the admin user on the very first start against a completely empty database. If `kc.sh import` runs before the bootstrap start, it creates the master realm in the DB. Then the bootstrap start sees an existing DB and skips admin creation.

**Fix:** The setup script now starts Keycloak on the fresh DB FIRST (creating the admin user), then imports the realm via `kcadm.sh` (which works against a running instance). Order matters: admin first, import second.

### Realm import doesn't create clients

**Symptom:** The `spm` realm exists but only has default clients (account, admin-cli, etc.). Custom clients like `spm-frontend` and `spm-backend` are missing.

**Cause:** `kcadm.sh create realms -f realm-export.json` creates the realm but doesn't reliably import nested objects like clients.

**Fix:** Use a two-step approach:
1. `kcadm.sh create realms -s realm=spm -s enabled=true` — creates the empty realm
2. `kcadm.sh create partialImport -r spm -s ifResourceExists=SKIP -f realm-export.json` — imports clients, roles, etc. into the realm

### Keycloak health check fails (ALB target unhealthy)

**Symptom:** The `kc-tg` target group shows unhealthy in the ALB console.

**Cause:** Keycloak 26.x serves health endpoints on the management port (9000), not the main HTTP port (8443). The `http-relative-path=/auth` is inherited, so health is at `:9000/auth/health/ready`.

**Fix:**
- ALB health check: port `9000`, path `/auth/health/ready`
- Security group: allow port 9000 from ALB SG (not just Prometheus)
- `health-enabled=true` must be in `keycloak.conf` at build time (not just on the start command)

---

## Backend

### "The iss claim is not valid" (JWT 401)

**Symptom:** Backend returns 401 for all authenticated requests. Debug logs show "The iss claim is not valid."

**Cause:** The JWT token's `iss` claim is `https://spm.eggtive.com/auth/realms/spm` (the public URL from Keycloak's `hostname` setting), but the backend's `KEYCLOAK_ISSUER_URI` was set to `http://keycloak.internal.dev.eggtive-spm:8443/auth/realms/spm` (the internal URL). They don't match.

**Fix:** Two separate env vars:
- `KEYCLOAK_ISSUER_URI=https://<custom_domain>/auth/realms/spm` — matches the token's `iss` claim (public URL)
- `KEYCLOAK_JWK_SET_URI=http://keycloak.internal...:8443/auth/realms/spm/protocol/openid-connect/certs` — internal URL the backend can actually reach to fetch signing keys

### "Failed to configure a DataSource: 'url' attribute is not specified"

**Symptom:** Backend crashes on startup with a DataSource error. `SPRING_DATASOURCE_URL` is empty in the env file.

**Cause:** The SSM parameter for the DB URL wasn't available when the userdata ran — the RDS was still being created by Terraform in parallel.

**Fix:**
1. `depends_on` in Terraform ensures RDS + SSM params exist before EC2 creation
2. Backend setup script (`ExecStartPre`) reads SSM on every start, not just during userdata
3. Self-healing: if SSM read fails, systemd retries every 30s

### Backend env file gets overwritten on restart

**Symptom:** You manually fix the env file, restart the backend, and the fix is gone.

**Cause:** The `ExecStartPre` setup script re-reads SSM and rewrites the env file on every restart. Manual edits are overwritten.

**Fix:** Edit the setup script itself (`/opt/deploy/backend-setup.sh`) in addition to the env file. Or better: fix the Terraform template and taint the EC2.

---

## Terraform / Make

### S3 bucket deletion fails on `terraform destroy`

**Symptom:** `BucketNotEmpty: The bucket you tried to delete is not empty. You must delete all versions.`

**Cause:** S3 buckets with versioning enabled can't be deleted until all object versions are removed.

**Fix:** `force_destroy = var.environment == "dev"` on S3 bucket resources. This lets Terraform empty the bucket automatically on destroy for dev. Prod keeps `force_destroy = false` for safety.

### EC2 userdata changes don't take effect

**Symptom:** You update a userdata template but the running EC2 still has the old config.

**Cause:** Userdata only runs on first boot. Updating the template in Terraform changes the launch config but doesn't re-run userdata on existing instances.

**Fix:** Taint the EC2 and re-apply:
```bash
make taint-keycloak   # or taint-backend, taint-prometheus, taint-all
make up
```

### Circular dependency: VPC origin ↔ CloudFront distribution

**Symptom:** `Error: Cycle: aws_cloudfront_vpc_origin.alb, aws_cloudfront_distribution.main`

**Cause:** The distribution references the VPC origin (via `vpc_origin_id`), and adding `depends_on = [aws_cloudfront_distribution.main]` to the VPC origin creates a cycle.

**Fix:** Cannot use `depends_on` between these two resources. The async deletion issue must be handled via the manual workaround (see VPC origin deletion above).

---

## Frontend

### Login succeeds but redirects back to /login

**Symptom:** Keycloak login works (auth code in URL), but the app redirects to `/login` instead of the dashboard.

**Cause:** The frontend Keycloak adapter was configured with `http://localhost:8180` (local dev URL) instead of `https://spm.eggtive.com/auth`. The token exchange fails silently.

**Fix:** Set frontend build-time env vars correctly:
```
KEYCLOAK_URL=https://spm.eggtive.com/auth
KEYCLOAK_REALM=spm
KEYCLOAK_CLIENT_ID=spm-frontend
API_BASE_URL=https://spm.eggtive.com/api/v1
```
These are baked into the React build — rebuild and redeploy the frontend after changing them.

### No /api/* requests visible in Network tab

**Symptom:** After login, no API calls are made. The frontend goes straight to `/login`.

**Cause:** The Keycloak JS adapter failed to exchange the auth code for a token (wrong Keycloak URL in frontend config). Without a token, the frontend considers the user unauthenticated.

**Fix:** Same as above — correct the `KEYCLOAK_URL` in the frontend build env vars.
