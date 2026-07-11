environment            = "dev"
custom_domain          = "dev.spm.eggtive.com"
vpc_cidr               = "10.0.0.0/16"
private_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
backend_instance_type  = "t3.nano"
keycloak_instance_type = "t3.small"
db_instance_class      = "db.t3.micro"
domain_name            = "internal.dev.eggtive-spm"

# env_active is controlled via GitHub environment variable (ENV_ACTIVE)
# Locally: use -var="env_active=true/false" override
# CI reads from: ${{ vars.ENV_ACTIVE }}

# GitHub OIDC
github_org  = "mintun-myo-2020"
github_repo = "eggtive-infra"

# Trusted app repos — each gets a scoped deploy role
trusted_apps = {
  spm = {
    github_repo = "spm"
  }
  social = {
    github_repo = "social"
  }
}
tenant_name = "Eggtive SPM"

# Container workloads (ECS Fargate)
container_workloads = {
  social = {
    cpu           = 256
    memory        = 512
    port          = 8080
    desired_count = 1
    runtime       = "go"

    database = {
      instance_class = "db.t3.micro"
      db_name        = "socialdb"
    }

    frontend = {
      subdomain = "social"
    }
  }
}
