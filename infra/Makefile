.PHONY: bootstrap init up update down status plan-up plan-down \
	seed seed-artifacts seed-realm seed-backend seed-frontend seed-all \
	deploy-dev \
	taint-backend taint-keycloak taint-prometheus taint-all \
	ssh-backend ssh-keycloak ssh-prometheus prometheus-ui

ENV := dev
TF_VARS := -var-file=envs/$(ENV).tfvars
STATE_BUCKET := eggtive-spm-terraform-state
LOCK_TABLE := terraform-locks
REGION := ap-southeast-1
PROJECT := eggtive-spm

# --- Local dist files (downloaded once, gitignored) ---
KEYCLOAK_DIST := dist/keycloak-26.1.0.tar.gz
PROMETHEUS_DIST := dist/prometheus-3.5.1.linux-amd64.tar.gz
GRAFANA_DIST := dist/grafana_13.0.1_24542347077_linux_amd64.rpm

# --- App build artifacts (from the app repo, optional) ---
BACKEND_JAR := ../backend/build/libs/backend.jar
FRONTEND_BUILD := ../frontend/build

# ============================================================
# Bootstrap (one-time: create state bucket + lock table)
# ============================================================
bootstrap:
	@echo "Creating state bucket $(STATE_BUCKET)..."
	aws s3api create-bucket --bucket $(STATE_BUCKET) --region $(REGION) \
		--create-bucket-configuration LocationConstraint=$(REGION)
	aws s3api put-bucket-versioning --bucket $(STATE_BUCKET) \
		--versioning-configuration Status=Enabled
	aws s3api put-public-access-block --bucket $(STATE_BUCKET) \
		--public-access-block-configuration \
		BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
	@echo "Creating lock table $(LOCK_TABLE)..."
	aws dynamodb create-table \
		--table-name $(LOCK_TABLE) \
		--attribute-definitions AttributeName=LockID,AttributeType=S \
		--key-schema AttributeName=LockID,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST \
		--region $(REGION)
	@echo "Done. Run: make init"

init:
	terraform init

# ============================================================
# Environment lifecycle
#
# make up      — FIRST-TIME bootstrap only
#                Phase 1: base infra (S3, VPC, CloudFront, IAM)
#                Phase 2: upload artifacts to S3
#                Phase 3: compute (EC2s, RDS, ALB, VPC endpoints)
#
# make update  — ONGOING changes (add observability, update userdata, etc.)
#                Single terraform apply. Does NOT destroy ALB/VPC origin.
#                Use this after changing .tf files or userdata templates.
#
# make down    — Tear down on-demand resources (EC2s, RDS, ALB, VPC endpoints)
#                Uses CLI to detach CloudFront → VPC origin before Terraform
#                destroys compute. See TROUBLESHOOTING.md for details.
#                S3 buckets + artifacts persist.
# ============================================================

up:
	@if terraform state show 'aws_instance.backend[0]' > /dev/null 2>&1 \
		|| terraform state show 'aws_db_instance.main[0]' > /dev/null 2>&1 \
		|| terraform state show 'aws_lb.main[0]' > /dev/null 2>&1; then \
		echo "ERROR: Environment is already up (or partially up). Use 'make update' for changes."; \
		exit 1; \
	fi
	@echo "=== Phase 1: Base infrastructure (S3, VPC, CloudFront, IAM) ==="
	terraform apply $(TF_VARS) -var="env_active=false" -auto-approve
	@echo ""
	@echo "=== Phase 2: Upload infra artifacts to S3 ==="
	@test -f $(KEYCLOAK_DIST) && \
		aws s3 cp $(KEYCLOAK_DIST) s3://$(PROJECT)-artifacts/keycloak/keycloak.tar.gz \
		|| (echo "ERROR: $(KEYCLOAK_DIST) not found. Download it first." && exit 1)
	@test -f $(PROMETHEUS_DIST) && \
		aws s3 cp $(PROMETHEUS_DIST) s3://$(PROJECT)-artifacts/prometheus/prometheus.tar.gz \
		|| (echo "ERROR: $(PROMETHEUS_DIST) not found. Download it first." && exit 1)
	@test -f $(GRAFANA_DIST) && \
		aws s3 cp $(GRAFANA_DIST) s3://$(PROJECT)-artifacts/grafana/grafana.rpm \
		|| (echo "ERROR: $(GRAFANA_DIST) not found. Download it first." && exit 1)
	@test -f exports/realm-export.json && \
		aws s3 cp exports/realm-export.json s3://$(PROJECT)-artifacts/keycloak/realm-export.json \
		|| echo "SKIP: exports/realm-export.json not found"
	@if [ -f exports/realm-export-dev-users.json ]; then \
		aws s3 cp exports/realm-export-dev-users.json s3://$(PROJECT)-artifacts/keycloak/realm-export-dev-users.json; \
	fi
	@echo ""
	@echo "=== Phase 3: Compute (EC2s, RDS, ALB, VPC endpoints) ==="
	terraform apply $(TF_VARS) -var="env_active=true" -auto-approve
	@echo ""
	@echo "=== Done. Environment is up. ==="
	@echo "Backend JAR: upload via app repo CI or 'make seed-backend'"

update:
	@echo "=== Uploading artifacts to S3 (if present) ==="
	@test -f $(KEYCLOAK_DIST) && \
		aws s3 cp $(KEYCLOAK_DIST) s3://$(PROJECT)-artifacts/keycloak/keycloak.tar.gz \
		|| echo "SKIP: $(KEYCLOAK_DIST) not found (OK if already in S3)"
	@test -f $(PROMETHEUS_DIST) && \
		aws s3 cp $(PROMETHEUS_DIST) s3://$(PROJECT)-artifacts/prometheus/prometheus.tar.gz \
		|| echo "SKIP: $(PROMETHEUS_DIST) not found (OK if already in S3)"
	@test -f $(GRAFANA_DIST) && \
		aws s3 cp $(GRAFANA_DIST) s3://$(PROJECT)-artifacts/grafana/grafana.rpm \
		|| echo "SKIP: $(GRAFANA_DIST) not found (OK if already in S3)"
	@test -f exports/realm-export.json && \
		aws s3 cp exports/realm-export.json s3://$(PROJECT)-artifacts/keycloak/realm-export.json \
		|| echo "SKIP: exports/realm-export.json not found"
	@if [ -f exports/realm-export-dev-users.json ]; then \
		aws s3 cp exports/realm-export-dev-users.json s3://$(PROJECT)-artifacts/keycloak/realm-export-dev-users.json; \
	fi
	@echo ""
	@echo "=== Importing pre-existing log groups (if any) ==="
	-terraform import $(TF_VARS) -var="env_active=true" 'aws_cloudwatch_log_group.services["/$(PROJECT)/$(ENV)/backend"]' /$(PROJECT)/$(ENV)/backend
	-terraform import $(TF_VARS) -var="env_active=true" 'aws_cloudwatch_log_group.services["/$(PROJECT)/$(ENV)/keycloak"]' /$(PROJECT)/$(ENV)/keycloak
	-terraform import $(TF_VARS) -var="env_active=true" 'aws_cloudwatch_log_group.services["/$(PROJECT)/$(ENV)/prometheus"]' /$(PROJECT)/$(ENV)/prometheus
	-terraform import $(TF_VARS) -var="env_active=true" 'aws_cloudwatch_log_group.services["/$(PROJECT)/$(ENV)/userdata"]' /$(PROJECT)/$(ENV)/userdata
	@echo ""
	@echo "=== Applying changes ==="
	terraform apply $(TF_VARS) -var="env_active=true" -auto-approve
	@echo ""
	@echo "=== Done. ==="

# ============================================================
# make down — CLI-based teardown
#
# CloudFront refuses to delete a VPC origin that's still associated
# with a distribution. Terraform tries to do both in one apply and
# fails with CannotDeleteEntityWhileInUse. Workaround:
#
#   1. CLI: patch CloudFront config to remove ALB origin + switch
#      /api/* and /auth/* behaviors to s3-frontend
#   2. CLI: wait for CloudFront to finish deploying
#   3. CLI: delete the now-orphaned VPC origin
#   4. TF:  remove VPC origin from state (already deleted by CLI)
#   5. TF:  terraform apply env_active=false (destroys remaining
#      compute: EC2s, RDS, ALB, SGs, VPC endpoints, log groups)
#
# On `make up`, Terraform recreates the VPC origin + ALB origin
# from scratch (they're not in state, so it treats them as new).
# ============================================================
down:
	@echo "=== Phase 1: Remove ALB origin from CloudFront (CLI) ==="
	@DIST_ID=$$(terraform output -raw cloudfront_distribution_id) && \
	HAS_ALB=$$(aws cloudfront get-distribution-config --id $$DIST_ID --query 'DistributionConfig.Origins.Items[?Id==`alb-backend`]' --output text) && \
	if [ -n "$$HAS_ALB" ]; then \
		ETAG=$$(aws cloudfront get-distribution-config --id $$DIST_ID --query 'ETag' --output text) && \
		aws cloudfront get-distribution-config --id $$DIST_ID --query 'DistributionConfig' --output json \
			| python3 -c "\
import sys, json; \
c = json.load(sys.stdin); \
c['Origins']['Items'] = [o for o in c['Origins']['Items'] if o['Id'] != 'alb-backend']; \
c['Origins']['Quantity'] = len(c['Origins']['Items']); \
[b.update({'TargetOriginId': 's3-frontend'}) for b in c.get('CacheBehaviors', {}).get('Items', []) if b.get('TargetOriginId') == 'alb-backend']; \
json.dump(c, sys.stdout)" \
			| aws cloudfront update-distribution --id $$DIST_ID --if-match $$ETAG --distribution-config file:///dev/stdin > /dev/null && \
		echo "CloudFront updated — ALB origin removed"; \
	else \
		echo "ALB origin already removed — skipping"; \
	fi
	@echo ""
	@echo "=== Phase 2: Wait for CloudFront to deploy ==="
	@aws cloudfront wait distribution-deployed --id $$(terraform output -raw cloudfront_distribution_id)
	@echo "CloudFront deployed"
	@echo ""
	@echo "=== Phase 3: Delete VPC origin (CLI) ==="
	@if terraform state show 'aws_cloudfront_vpc_origin.alb[0]' > /dev/null 2>&1; then \
		VPC_ORIGIN_ID=$$(terraform state show 'aws_cloudfront_vpc_origin.alb[0]' 2>/dev/null | grep '^ *id ' | awk '{print $$3}' | tr -d '"') && \
		ETAG=$$(aws cloudfront get-vpc-origin --id $$VPC_ORIGIN_ID --query 'ETag' --output text) && \
		aws cloudfront delete-vpc-origin --id $$VPC_ORIGIN_ID --if-match $$ETAG > /dev/null && \
		echo "VPC origin $$VPC_ORIGIN_ID deleted"; \
	else \
		echo "No VPC origin in state — skipping"; \
	fi
	@echo ""
	@echo "=== Phase 4: Remove CLI-deleted resources from Terraform state ==="
	-terraform state rm 'aws_cloudfront_vpc_origin.alb[0]'
	@echo ""
	@echo "=== Phase 5: Destroy remaining compute ==="
	terraform apply $(TF_VARS) -var="env_active=false" -auto-approve
	@echo ""
	@echo "=== Done. Compute is down, data (S3/SSM/CloudFront) preserved. ==="

destroy:
	@echo "=== WARNING: This will destroy ALL resources including S3 and data ==="
	terraform destroy $(TF_VARS) -auto-approve

status:
	@terraform output env_active

plan-up:
	terraform plan $(TF_VARS) -var="env_active=true"

plan-down:
	terraform plan $(TF_VARS) -var="env_active=false"

# ============================================================
# Seed — manual artifact upload
# ============================================================

seed-artifacts:
	@echo "Uploading Keycloak tarball..."
	@test -f $(KEYCLOAK_DIST) || (echo "ERROR: $(KEYCLOAK_DIST) not found." && exit 1)
	aws s3 cp $(KEYCLOAK_DIST) s3://$(PROJECT)-artifacts/keycloak/keycloak.tar.gz
	@echo "Uploading Prometheus tarball..."
	@test -f $(PROMETHEUS_DIST) || (echo "ERROR: $(PROMETHEUS_DIST) not found." && exit 1)
	aws s3 cp $(PROMETHEUS_DIST) s3://$(PROJECT)-artifacts/prometheus/prometheus.tar.gz
	@echo "Uploading Grafana RPM..."
	@test -f $(GRAFANA_DIST) || (echo "ERROR: $(GRAFANA_DIST) not found." && exit 1)
	aws s3 cp $(GRAFANA_DIST) s3://$(PROJECT)-artifacts/grafana/grafana.rpm

seed-realm:
	@echo "Uploading Keycloak realm exports..."
	@test -f exports/realm-export.json || (echo "ERROR: exports/realm-export.json not found." && exit 1)
	aws s3 cp exports/realm-export.json s3://$(PROJECT)-artifacts/keycloak/realm-export.json
	@if [ -f exports/realm-export-dev-users.json ]; then \
		aws s3 cp exports/realm-export-dev-users.json s3://$(PROJECT)-artifacts/keycloak/realm-export-dev-users.json; \
		echo "Dev users export uploaded"; \
	fi

seed-backend:
	@test -f $(BACKEND_JAR) || (echo "ERROR: $(BACKEND_JAR) not found. Build your backend first." && exit 1)
	aws s3 cp $(BACKEND_JAR) s3://$(PROJECT)-artifacts/spm/spm-app.jar

seed-frontend:
	@test -d $(FRONTEND_BUILD) || (echo "ERROR: $(FRONTEND_BUILD) not found. Run npm build first." && exit 1)
	aws s3 sync $(FRONTEND_BUILD) s3://$(PROJECT)-$(ENV)-frontend/

seed: seed-artifacts seed-realm
	@echo "Infra artifacts uploaded."

seed-all: seed-artifacts seed-realm seed-backend seed-frontend
	@echo "All artifacts uploaded (infra + app)."

# ============================================================
# Deploy — push app code to running instances
# ============================================================

deploy-dev:
	aws ssm send-command \
		--document-name "AWS-RunShellScript" \
		--targets "Key=tag:Service,Values=backend" "Key=tag:Environment,Values=dev" \
		--parameters 'commands=["bash /opt/deploy/deploy.sh"]' \
		--comment "Deploy latest backend" \
		--output text

# ============================================================
# Taint — force recreate on next apply
# ============================================================

taint-backend:
	terraform taint 'aws_instance.backend[0]'

taint-keycloak:
	terraform taint 'aws_instance.keycloak[0]'

taint-prometheus:
	terraform taint 'aws_instance.prometheus[0]'

taint-all: taint-backend taint-keycloak taint-prometheus

# ============================================================
# Secrets — retrieve credentials
# ============================================================

keycloak-password:
	@aws ssm get-parameter --name "/$(PROJECT)/$(ENV)/keycloak/admin/password" --with-decryption --query 'Parameter.Value' --output text --region $(REGION)

# ============================================================
# SSM — shell into instances
# ============================================================

ssh-backend:
	aws ssm start-session --target $$(terraform output -raw backend_instance_id)

ssh-keycloak:
	aws ssm start-session --target $$(terraform output -raw keycloak_instance_id)

ssh-prometheus:
	aws ssm start-session --target $$(terraform output -raw prometheus_instance_id)

# ============================================================
# Port forwarding — access UIs locally
# ============================================================

prometheus-ui:
	@echo "Opening Prometheus UI at http://localhost:9090"
	aws ssm start-session \
		--target $$(terraform output -raw prometheus_instance_id) \
		--document-name AWS-StartPortForwardingSession \
		--parameters '{"portNumber":["9090"],"localPortNumber":["9090"]}'

grafana-ui:
	@echo "Opening Grafana at http://localhost:3000 (default login: admin/admin)"
	aws ssm start-session \
		--target $$(terraform output -raw prometheus_instance_id) \
		--document-name AWS-StartPortForwardingSession \
		--parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
