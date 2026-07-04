#!/bin/bash
set -uo pipefail

# ============================================================
# Generic app instance userdata
# Runtime: ${runtime}
# App: ${app_name}
# ============================================================

# --- Install runtime ---
%{ if runtime == "java21" ~}
dnf install -y java-21-amazon-corretto-headless
%{ endif ~}
%{ if runtime == "java25" ~}
dnf install -y java-25-amazon-corretto-headless
%{ endif ~}
%{ if runtime == "python3" ~}
dnf install -y python3 python3-pip
%{ endif ~}
%{ if runtime == "node20" ~}
dnf install -y nodejs20
%{ endif ~}
%{ if runtime == "go" ~}
# Go binary — no runtime needed
%{ endif ~}

dnf install -y amazon-cloudwatch-agent
useradd -r -s /bin/false appuser || true
mkdir -p /opt/app /opt/deploy /var/log/app
touch /var/log/app/${app_name}.log

# --- CloudWatch agent ---
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWCONFIG
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app/${app_name}.log",
            "log_group_name": "/${project_name}/${environment}/${app_name}",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/${project_name}/${environment}/userdata",
            "log_stream_name": "${app_name}-{instance_id}"
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
# Setup script (ExecStartPre — downloads artifact + reads SSM)
# ============================================================

cat > /opt/deploy/${app_name}-setup.sh <<'SETUP'
#!/bin/bash
set -euo pipefail

ARTIFACT="/opt/app/artifact"

# Download artifact if not present
if [ ! -f "$ARTIFACT" ]; then
  echo "Downloading artifact from S3..."
  aws s3 cp "s3://${s3_artifact_bucket}/${app_name}/${artifact}" "$ARTIFACT"
  chmod +x "$ARTIFACT"
  chown appuser:appuser "$ARTIFACT"
  echo "Artifact downloaded"
fi

# Read all SSM params under this app's prefix → env file
echo "Reading config from SSM..."
aws ssm get-parameters-by-path \
  --path "${ssm_prefix}/${app_name}/" \
  --with-decryption \
  --recursive \
  --query 'Parameters[*].[Name,Value]' \
  --output text \
  --region ${aws_region} \
| while IFS=$'\t' read -r name value; do
  # Convert SSM path to env var name: /<project>/<env>/<app>/db/url → DB_URL
  key=$(echo "$name" | sed "s|${ssm_prefix}/${app_name}/||" | tr '/' '_' | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  echo "$key=$value"
done > /opt/app/${app_name}.env

chmod 600 /opt/app/${app_name}.env
chown appuser:appuser /opt/app/${app_name}.env
echo "Setup complete"
SETUP
chmod +x /opt/deploy/${app_name}-setup.sh

# --- Deploy script (for CI/CD — re-downloads artifact) ---
cat > /opt/deploy/deploy.sh <<'DEPLOY'
#!/bin/bash
set -euo pipefail
aws s3 cp "s3://${s3_artifact_bucket}/${app_name}/${artifact}" /opt/app/artifact
chmod +x /opt/app/artifact
chown appuser:appuser /opt/app/artifact
systemctl restart ${app_name}
DEPLOY
chmod +x /opt/deploy/deploy.sh

# ============================================================
# systemd unit
# ============================================================

%{ if startswith(runtime, "java") ~}
RUN_CMD="/usr/bin/java -jar /opt/app/artifact"
%{ endif ~}
%{ if runtime == "go" ~}
RUN_CMD="/opt/app/artifact"
%{ endif ~}
%{ if runtime == "python3" ~}
RUN_CMD="/usr/bin/python3 /opt/app/artifact"
%{ endif ~}
%{ if runtime == "node20" ~}
RUN_CMD="/usr/bin/node /opt/app/artifact"
%{ endif ~}

cat > /etc/systemd/system/${app_name}.service <<UNIT
[Unit]
Description=${app_name} application
After=network.target

[Service]
Type=simple
ExecStartPre=+/opt/deploy/${app_name}-setup.sh
ExecStart=$RUN_CMD
User=appuser
EnvironmentFile=/opt/app/${app_name}.env
StandardOutput=append:/var/log/app/${app_name}.log
StandardError=append:/var/log/app/${app_name}.log
Restart=always
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ${app_name}
echo "${app_name} service enabled and starting"
