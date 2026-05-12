# ── Core ──────────────────────────────────────────────────────────────────────
aws_region         = "eu-central-1"
cluster_name       = "hrs-platform"
environment        = "production"
kubernetes_version = "1.32"

# ── Network ───────────────────────────────────────────────────────────────────
vpc_cidr             = "10.0.0.0/16"
availability_zones   = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

# ── EKS Nodes ─────────────────────────────────────────────────────────────────
node_instance_type = "t3.medium"
node_min_size      = 2
node_desired_size  = 3
node_max_size      = 10

# ── RDS ───────────────────────────────────────────────────────────────────────
rds_instance_class   = "db.t3.medium"
rds_database_name    = "hrs_platform"
rds_master_username  = "hrs_admin"
# rds_master_password — injected at apply time via TF_VAR_rds_master_password
# Never commit this value to git.

# ── Domain ────────────────────────────────────────────────────────────────────
domain_name = "platform.hrstravel.com"

# ── Storage ───────────────────────────────────────────────────────────────────
s3_shard_count = 15

# ── GitHub ────────────────────────────────────────────────────────────────────
github_org  = "hrs-group"
github_repo = "platform-app"

# ── Terraform State ───────────────────────────────────────────────────────────
terraform_state_bucket     = "hrs-platform-terraform-state"
terraform_state_lock_table = "hrs-platform-terraform-locks"

# ── Tenants ───────────────────────────────────────────────────────────────────
# Add teams here to provision full set of namespace, RBAC, IRSA, ECR, and secrets.
teams = {
  "team-01" = { quota_cpu = "10", quota_memory = "20Gi" }
  "team-02" = { quota_cpu = "10", quota_memory = "20Gi" }
  "team-03" = { quota_cpu = "10", quota_memory = "20Gi" }
}

# ── Observability ─────────────────────────────────────────────────────────────
# newrelic_license_key — injected at apply time via TF_VAR_newrelic_license_key
# Never commit this value to git.
