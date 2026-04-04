#!/bin/bash
set -uo pipefail

# ============================================================
# Phase 1: System setup (always succeeds, no S3 dependency)
# ============================================================

dnf install -y java-21-amazon-corretto-headless postgresql16 amazon-cloudwatch-agent
useradd -r -s /bin/false keycloak || true
mkdir -p /opt/keycloak /opt/deploy /opt/keycloak/conf

# Log directory for service stdout/stderr (systemd will write here)
mkdir -p /var/log/app
touch /var/log/app/keycloak.log

# CloudWatch agent config — ships keycloak service logs + setup script logs
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWCONFIG
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app/keycloak.log",
            "log_group_name": "/eggtive-spm/${environment}/keycloak",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/eggtive-spm/${environment}/userdata",
            "log_stream_name": "keycloak-{instance_id}"
          }
        ]
      }
    }
  }
}
CWCONFIG
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# Pull config from SSM Parameter Store
KC_DB_URL=$(aws ssm get-parameter --name "${ssm_prefix}/keycloak/db/url" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
KC_DB_USERNAME=$(aws ssm get-parameter --name "${ssm_prefix}/keycloak/db/username" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
KC_DB_PASSWORD=$(aws ssm get-parameter --name "${ssm_prefix}/keycloak/db/password" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
KC_ADMIN_PASSWORD=$(aws ssm get-parameter --name "${ssm_prefix}/keycloak/admin/password" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})

# Create keycloakdb if it doesn't exist
DB_HOST=$(echo "$KC_DB_URL" | sed 's|jdbc:postgresql://||;s|:.*||')
if PGPASSWORD="$KC_DB_PASSWORD" psql -h "$DB_HOST" -U "$KC_DB_USERNAME" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'keycloakdb'" | grep -q 1; then
  echo "keycloakdb already exists"
elif PGPASSWORD="$KC_DB_PASSWORD" psql -h "$DB_HOST" -U "$KC_DB_USERNAME" -d postgres -c "CREATE DATABASE keycloakdb"; then
  echo "keycloakdb created"
else
  echo "ERROR: failed to create keycloakdb"
fi

# Write Keycloak config (staging -- setup script copies after tarball extraction)
cat > /opt/deploy/keycloak.conf <<EOF
db=postgres
db-url=$KC_DB_URL
db-username=$KC_DB_USERNAME
db-password=$KC_DB_PASSWORD
hostname=https://${custom_domain}/auth
http-enabled=true
http-port=8443
http-relative-path=/auth
health-enabled=true
metrics-enabled=true
EOF

echo "$KC_ADMIN_PASSWORD" > /opt/deploy/kc-admin-password
chmod 600 /opt/deploy/kc-admin-password
chown -R keycloak:keycloak /opt/keycloak

# ============================================================
# Phase 2: Setup script (systemd ExecStartPre, fully idempotent)
# ============================================================
cat > /opt/deploy/keycloak-setup.sh <<SETUP
#!/bin/bash
set -euo pipefail

KC_HOME="/opt/keycloak"
KC_ADMIN_PW=\$(cat /opt/deploy/kc-admin-password)

# --- Download + build if needed ---
if [ ! -f "\$KC_HOME/bin/kc.sh" ]; then
  echo "Downloading Keycloak from S3..."
  aws s3 cp "s3://${s3_artifact_bucket}/keycloak/keycloak.tar.gz" /tmp/keycloak.tar.gz
  tar -xzf /tmp/keycloak.tar.gz -C "\$KC_HOME" --strip-components=1
  rm /tmp/keycloak.tar.gz
  cp /opt/deploy/keycloak.conf "\$KC_HOME/conf/keycloak.conf"
  chown -R keycloak:keycloak "\$KC_HOME"
  echo "Building Keycloak..."
  sudo -u keycloak "\$KC_HOME/bin/kc.sh" build
fi

cp /opt/deploy/keycloak.conf "\$KC_HOME/conf/keycloak.conf"
chown keycloak:keycloak "\$KC_HOME/conf/keycloak.conf"

# --- Skip if already bootstrapped ---
if [ -f /opt/deploy/kc-bootstrap-done ]; then
  echo "Bootstrap already done -- skipping"
  exit 0
fi

# --- Start Keycloak temporarily for bootstrap ---
echo "Starting Keycloak for bootstrap..."
sudo -u keycloak env KEYCLOAK_ADMIN=admin KEYCLOAK_ADMIN_PASSWORD="\$KC_ADMIN_PW" \
  "\$KC_HOME/bin/kc.sh" start --optimized &
KC_PID=\$!

for i in \$(seq 1 60); do
  if curl -sf http://localhost:9000/auth/health/ready >/dev/null 2>&1; then
    echo "Keycloak is ready"
    sleep 5
    break
  fi
  sleep 2
done

# --- Verify admin login ---
ADMIN_OK=false
for i in \$(seq 1 10); do
  if "\$KC_HOME/bin/kcadm.sh" config credentials --server http://localhost:8443/auth --realm master --user admin --password "\$KC_ADMIN_PW" 2>/dev/null; then
    echo "Admin login OK"
    ADMIN_OK=true
    break
  fi
  sleep 3
done

if [ "\$ADMIN_OK" = false ]; then
  echo "ERROR: Cannot login as admin"
  kill \$KC_PID 2>/dev/null || true
  wait \$KC_PID 2>/dev/null || true
  exit 1
fi

# --- Import spm realm if missing ---
if ! "\$KC_HOME/bin/kcadm.sh" get realms/spm >/dev/null 2>&1; then
  echo "spm realm not found -- importing..."
  mkdir -p /tmp/kc-import
  aws s3 cp "s3://${s3_artifact_bucket}/keycloak/realm-export.json" /tmp/kc-import/realm-export.json 2>/dev/null || true
  if [ "${environment}" = "dev" ]; then
    aws s3 cp "s3://${s3_artifact_bucket}/keycloak/realm-export-dev-users.json" /tmp/kc-import/realm-export-dev-users.json 2>/dev/null || true
  fi
  for f in /tmp/kc-import/*.json; do
    [ -f "\$f" ] || continue
    REALM_NAME=\$(python3 -c "import json; print(json.load(open('\$f')).get('realm',''))" 2>/dev/null || true)
    if [ -n "\$REALM_NAME" ]; then
      echo "Creating realm \$REALM_NAME..."
      "\$KC_HOME/bin/kcadm.sh" create realms -s "realm=\$REALM_NAME" -s enabled=true 2>/dev/null || true
      echo "Running partialImport for \$REALM_NAME..."
      "\$KC_HOME/bin/kcadm.sh" create partialImport -r "\$REALM_NAME" -s ifResourceExists=SKIP -f "\$f" 2>/dev/null || echo "partialImport warning (may be OK)"
    fi
  done
  rm -rf /tmp/kc-import
else
  echo "spm realm exists -- skipping import"
fi

# --- Sync spm-backend client secret from SSM ---
KC_CLIENT_SECRET=\$(aws ssm get-parameter --name "${ssm_prefix}/keycloak/client-secret" --with-decryption --query 'Parameter.Value' --output text --region ${aws_region})
CLIENT_ID=\$("\$KC_HOME/bin/kcadm.sh" get clients -r spm -q clientId=spm-backend --fields id --format csv --noquotes 2>/dev/null | head -1)
if [ -n "\$CLIENT_ID" ]; then
  "\$KC_HOME/bin/kcadm.sh" update "clients/\$CLIENT_ID" -r spm -s "secret=\$KC_CLIENT_SECRET" 2>/dev/null
  echo "spm-backend client secret synced"
else
  echo "WARNING: spm-backend client not found"
fi

kill \$KC_PID 2>/dev/null || true
wait \$KC_PID 2>/dev/null || true
touch /opt/deploy/kc-bootstrap-done
echo "Bootstrap complete"
SETUP
chmod +x /opt/deploy/keycloak-setup.sh

# ============================================================
# Phase 3: systemd unit
# ============================================================
cat > /etc/systemd/system/keycloak.service <<'UNIT'
[Unit]
Description=Keycloak Identity Provider
After=network.target

[Service]
Type=simple
ExecStartPre=+/opt/deploy/keycloak-setup.sh
ExecStart=!/opt/keycloak/bin/kc.sh start --health-enabled=true --metrics-enabled=true
User=keycloak
Environment=KEYCLOAK_ADMIN=admin
Environment=KEYCLOAK_ADMIN_PASSWORD=changeme
StandardOutput=append:/var/log/app/keycloak.log
StandardError=append:/var/log/app/keycloak.log
Restart=always
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /etc/systemd/system/keycloak.service.d
cat > /etc/systemd/system/keycloak.service.d/override.conf <<EOF
[Service]
Environment=KEYCLOAK_ADMIN_PASSWORD=$KC_ADMIN_PASSWORD
EOF

systemctl daemon-reload
systemctl enable --now keycloak
echo "Keycloak service enabled and starting"
