# Keycloak admin password
resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "keycloak_admin_password" {
  name  = "/${var.project_name}/${var.environment}/keycloak/admin/password"
  type  = "SecureString"
  value = random_password.keycloak_admin.result
}

resource "aws_ssm_parameter" "keycloak_url" {
  name  = "/${var.project_name}/${var.environment}/keycloak/url"
  type  = "String"
  value = "http://keycloak.${var.domain_name}:8443/auth/realms/master"
}

# Keycloak backend client secret (auto-generated, used by spm-backend client)
resource "random_password" "keycloak_client_secret" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "keycloak_client_secret" {
  name  = "/${var.project_name}/${var.environment}/keycloak/client-secret"
  type  = "SecureString"
  value = random_password.keycloak_client_secret.result
}
