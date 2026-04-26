environment            = "dev"
custom_domain          = "dev.spm.eggtive.com"
vpc_cidr               = "10.0.0.0/16"
private_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
backend_instance_type  = "t3.nano"
keycloak_instance_type = "t3.small"
db_instance_class      = "db.t3.micro"
domain_name            = "internal.dev.eggtive-spm"

# env_active is NOT set here — controlled via CLI:
#   make up   → -var="env_active=true"
#   make down → -var="env_active=false"

# GitHub OIDC — update these to match your repo
github_org  = "mintun-myo-2020"
github_repo = "spm"
tenant_name = "Eggtive SPM"
