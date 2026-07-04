#!/bin/bash
set -uo pipefail

# ============================================================
# Phase 1: System setup (always succeeds, no S3 dependency)
# ============================================================

dnf install -y amazon-cloudwatch-agent
useradd -r -s /bin/false prometheus || true
mkdir -p /opt/prometheus /opt/prometheus/data /opt/deploy

# Log directory for service stdout/stderr (systemd will write here)
mkdir -p /var/log/app
touch /var/log/app/prometheus.log

# CloudWatch agent config — ships prometheus service logs + setup script logs
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWCONFIG
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app/prometheus.log",
            "log_group_name": "/${project_name}/${environment}/prometheus",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/${project_name}/${environment}/userdata",
            "log_stream_name": "prometheus-{instance_id}"
          }
        ]
      }
    }
  }
}
CWCONFIG
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# Write Prometheus config (staging — setup script restores after extraction)
cat > /opt/deploy/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: backend
    metrics_path: /actuator/prometheus
    static_configs:
      - targets: ['backend.${domain_name}:8080']

  - job_name: keycloak
    metrics_path: /auth/metrics
    static_configs:
      - targets: ['keycloak.${domain_name}:9000']
EOF

chown -R prometheus:prometheus /opt/prometheus

# ============================================================
# Phase 2: Setup script (called by systemd ExecStartPre)
# Retried automatically by systemd if tarball isn't in S3 yet
# ============================================================

cat > /opt/deploy/prometheus-setup.sh <<SETUP
#!/bin/bash
set -euo pipefail

if [ -f /opt/prometheus/prometheus ]; then
  echo "Prometheus binary exists — skipping download"
  # Always ensure config is up to date
  cp /opt/deploy/prometheus.yml /opt/prometheus/prometheus.yml
  chown prometheus:prometheus /opt/prometheus/prometheus.yml
  exit 0
fi

echo "Downloading Prometheus from S3..."
aws s3 cp "s3://${s3_artifact_bucket}/prometheus/prometheus.tar.gz" /tmp/prometheus.tar.gz
tar -xzf /tmp/prometheus.tar.gz -C /opt/prometheus --strip-components=1
rm /tmp/prometheus.tar.gz
# Restore our config (tarball may overwrite default prometheus.yml)
cp /opt/deploy/prometheus.yml /opt/prometheus/prometheus.yml
chown -R prometheus:prometheus /opt/prometheus
echo "Prometheus downloaded and extracted"
SETUP
chmod +x /opt/deploy/prometheus-setup.sh

# ============================================================
# Phase 3: systemd unit with ExecStartPre for self-healing
# ============================================================

cat > /etc/systemd/system/prometheus.service <<'UNIT'
[Unit]
Description=Prometheus Monitoring
After=network.target

[Service]
Type=simple
ExecStartPre=+/opt/deploy/prometheus-setup.sh
ExecStart=/opt/prometheus/prometheus \
  --config.file=/opt/prometheus/prometheus.yml \
  --storage.tsdb.path=/opt/prometheus/data \
  --storage.tsdb.retention.time=15d \
  --web.listen-address=:9090
User=prometheus
StandardOutput=append:/var/log/app/prometheus.log
StandardError=append:/var/log/app/prometheus.log
Restart=always
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now prometheus
echo "Prometheus service enabled and starting (will retry until tarball is in S3)"

# ============================================================
# Phase 4: Grafana (runs alongside Prometheus)
# ============================================================

# Install Grafana OSS from S3 (no internet access in private subnet)
aws s3 cp "s3://${s3_artifact_bucket}/grafana/grafana.rpm" /tmp/grafana.rpm
dnf install -y /tmp/grafana.rpm
rm /tmp/grafana.rpm

# Provision Prometheus data source
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml <<'DSEOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: false
  - name: CloudWatch
    type: cloudwatch
    access: proxy
    jsonData:
      authType: default
      defaultRegion: ${aws_region}
    editable: false
DSEOF

systemctl enable --now grafana-server
echo "Grafana enabled and starting on port 3000"
