#!/bin/bash
set -uo pipefail

# ============================================================
# Phase 1: System setup (always succeeds, no external dependency)
# ============================================================

dnf install -y java-25-amazon-corretto-headless amazon-cloudwatch-agent
useradd -r -s /bin/false appuser || true
mkdir -p /opt/app /opt/deploy

# Create empty env file so systemd can load it (ExecStartPre will populate it)
touch /opt/app/backend.env
chmod 600 /opt/app/backend.env
chown appuser:appuser /opt/app/backend.env

# Log directory for service stdout/stderr (systemd will write here)
mkdir -p /var/log/app
touch /var/log/app/backend.log

# CloudWatch agent config — ships backend service logs + setup script logs
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWCONFIG
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app/backend.log",
            "log_group_name": "/${project_name}/${environment}/backend",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/${project_name}/${environment}/userdata",
            "log_stream_name": "backend-{instance_id}"
          }
        ]
      }
    }
  }
}
CWCONFIG
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# ============================================================
# Phase 2: Setup script (called by systemd ExecStartPre)
# Downloads JAR + reads SSM config — retried automatically
# ============================================================

cat > /opt/deploy/backend-setup.sh <<SETUP
#!/bin/bash
set -euo pipefail

# Download JAR if not present
if [ ! -f /opt/app/backend.jar ]; then
  echo "Downloading backend JAR from S3..."
  aws s3 cp "s3://${s3_artifact_bucket}/spm/spm-app.jar" /opt/app/backend.jar
  chown appuser:appuser /opt/app/backend.jar
  echo "Backend JAR downloaded"
fi

# Always refresh config from SSM (ensures latest values)
echo "Reading config from SSM..."
DB_URL=\$(aws ssm get-parameter --name "${ssm_prefix}/db/url" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
DB_USERNAME=\$(aws ssm get-parameter --name "${ssm_prefix}/db/username" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
DB_PASSWORD=\$(aws ssm get-parameter --name "${ssm_prefix}/db/password" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
KC_URL=\$(aws ssm get-parameter --name "${ssm_prefix}/keycloak/url" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
KC_CLIENT_SECRET=\$(aws ssm get-parameter --name "${ssm_prefix}/keycloak/client-secret" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})

# KC_URL is http://keycloak.internal...:8443/auth/realms/master — extract base
KC_BASE=\$(echo "\$KC_URL" | sed 's|/realms/.*||')

cat > /opt/app/backend.env <<EOF
# --- Application ---
SERVER_PORT=8080

# --- Database ---
DB_URL=\$DB_URL
DB_USERNAME=\$DB_USERNAME
DB_PASSWORD=\$DB_PASSWORD

# --- Keycloak ---
KEYCLOAK_ISSUER_URI=https://${custom_domain}/auth/realms/spm
KEYCLOAK_JWK_SET_URI=\$KC_BASE/realms/spm/protocol/openid-connect/certs
KEYCLOAK_SERVER_URL=\$KC_BASE
KEYCLOAK_REALM=spm
KEYCLOAK_ADMIN_CLIENT_ID=spm-backend
KEYCLOAK_ADMIN_CLIENT_SECRET=\$KC_CLIENT_SECRET

# --- CORS ---
CORS_ALLOWED_ORIGINS=https://${custom_domain}

# --- Logging ---
LOG_LEVEL=INFO

# --- AWS Bedrock ---
APP_BEDROCK_REGION=${aws_region}
APP_EXTRACTION_TYPE=bedrock
APP_EXTRACTION_BEDROCK_MODEL_ID=global.amazon.nova-2-lite-v1:0
APP_EXTRACTION_BEDROCK_MODEL_ADAPTER=nova
APP_EXTRACTION_BEDROCK_REGION=${aws_region}
APP_LLM_TYPE=bedrock
APP_LLM_BEDROCK_MODEL_ID=global.amazon.nova-2-lite-v1:0
APP_LLM_BEDROCK_MODEL_ADAPTER=nova
APP_LLM_BEDROCK_REGION=${aws_region}

# --- Storage ---
APP_STORAGE_TYPE=${storage_type}
APP_STORAGE_S3_BUCKET=${uploads_bucket}
APP_REPORT_STORAGE_S3_BUCKET=${reports_bucket}
EOF

chmod 600 /opt/app/backend.env
chown appuser:appuser /opt/app/backend.env
echo "Backend setup complete"
SETUP
chmod +x /opt/deploy/backend-setup.sh

# Deploy script (for CI/CD — always re-downloads JAR)
cat > /opt/deploy/deploy.sh <<DEPLOY
#!/bin/bash
set -euo pipefail
aws s3 cp "s3://${s3_artifact_bucket}/spm/spm-app.jar" /opt/app/backend.jar
chown appuser:appuser /opt/app/backend.jar
systemctl restart backend
DEPLOY
chmod +x /opt/deploy/deploy.sh

# ============================================================
# Phase 3: systemd unit with ExecStartPre for self-healing
# ============================================================

cat > /etc/systemd/system/backend.service <<'UNIT'
[Unit]
Description=Backend Application
After=network.target

[Service]
Type=simple
ExecStartPre=+/opt/deploy/backend-setup.sh
ExecStart=/usr/bin/java -jar /opt/app/backend.jar
User=appuser
EnvironmentFile=/opt/app/backend.env
StandardOutput=append:/var/log/app/backend.log
StandardError=append:/var/log/app/backend.log
Restart=always
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now backend
echo "Backend service enabled and starting (will retry until JAR + SSM params are available)"
