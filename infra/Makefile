.PHONY: bootstrap init up down status plan-up plan-down \
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
# make up:
#   Phase 1 — terraform apply env_active=false
#             Creates S3 buckets, VPC, CloudFront, IAM, SSM, ACM
#             (no EC2s, no RDS, no ALB)
#
#   Phase 2 — upload infra artifacts to S3
#             Keycloak tarball, Prometheus tarball, realm exports
#             (backend JAR is uploaded by app repo CI, not here)
#
#   Phase 3 — terraform apply env_active=true
#             Creates EC2s, RDS, ALB, VPC endpoints, DNS, VPC origin
#             EC2s boot and find artifacts already in S3
#
# make down:
#   terraform apply env_active=false
#   Destroys EC2s, RDS, ALB, VPC endpoints
#   S3 buckets + artifacts persist
# ============================================================

up:
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
	@test -f exports/realm-export.json && \
		aws s3 cp exports/realm-export.json s3://$(PROJECT)-artifacts/keycloak/realm-export.json \
		|| echo "SKIP: exports/realm-export.json not found (realm won't be auto-imported)"
	@if [ -f exports/realm-export-dev-users.json ]; then \
		aws s3 cp exports/realm-export-dev-users.json s3://$(PROJECT)-artifacts/keycloak/realm-export-dev-users.json; \
	fi
	@echo ""
	@echo "=== Phase 3: Compute (EC2s, RDS, ALB, VPC endpoints) ==="
	terraform apply $(TF_VARS) -var="env_active=true" -auto-approve
	@echo ""
	@echo "=== Done. Environment is up. ==="
	@echo "Backend JAR: upload via app repo CI or 'make seed-backend'"

down:
	terraform apply $(TF_VARS) -var="env_active=false" -auto-approve

status:
	@terraform output env_active

plan-up:
	terraform plan $(TF_VARS) -var="env_active=true"

plan-down:
	terraform plan $(TF_VARS) -var="env_active=false"

# ============================================================
# Seed — manual artifact upload (for when you need to upload
# individual artifacts outside of make up)
# ============================================================

seed-artifacts:
	@echo "Uploading Keycloak tarball..."
	@test -f $(KEYCLOAK_DIST) || (echo "ERROR: $(KEYCLOAK_DIST) not found." && exit 1)
	aws s3 cp $(KEYCLOAK_DIST) s3://$(PROJECT)-artifacts/keycloak/keycloak.tar.gz
	@echo "Uploading Prometheus tarball..."
	@test -f $(PROMETHEUS_DIST) || (echo "ERROR: $(PROMETHEUS_DIST) not found." && exit 1)
	aws s3 cp $(PROMETHEUS_DIST) s3://$(PROJECT)-artifacts/prometheus/prometheus.tar.gz

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
	aws s3 cp $(BACKEND_JAR) s3://$(PROJECT)-artifacts/spm-app.jar

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
