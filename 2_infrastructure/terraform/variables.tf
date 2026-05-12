variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "cluster_name" {
  type    = string
  default = "hrs-platform"
}

variable "kubernetes_version" {
  type    = string
  default = "1.32"
  # EKS 1.32 — extended support until Feb 2027.
  # Upgrade path: 1.32 → 1.33 (Jun 2026) → 1.34 (Oct 2026).
}

variable "environment" {
  type    = string
  default = "production"
}

variable "domain_name" {
  type    = string
  default = "platform.hrstravel.com"
  # Public domain required — Let's Encrypt does not issue certs for .internal TLDs.
  # cert-manager uses DNS-01 challenge via Route53.
}

# EKS API endpoint access.
# `endpoint_public_access = false` is the most secure posture, but Terraform's
# kubernetes/helm providers run from outside the VPC and cannot reach a
# private-only endpoint during bootstrap. Production options:
#   1. Run Terraform from a bastion / self-hosted runner inside the VPC, set false here.
#   2. Keep public_access enabled but restrict via public_access_cidrs to admin IPs.
#   3. Bootstrap with public access enabled, then flip to false post-install.
variable "eks_endpoint_public_access" {
  type    = bool
  default = true
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the EKS public endpoint. Restrict to admin IPs in production."
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# 3 AZs for HA — matches the 3 NAT gateways required by 99.9% SLO.
variable "availability_zones" {
  type    = list(string)
  default = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 10
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "rds_database_name" {
  type    = string
  default = "hrs_platform"
}

variable "rds_master_username" {
  type    = string
  default = "hrs_admin"
}

# Injected at apply time — never committed to Git.
variable "rds_master_password" {
  type      = string
  sensitive = true
}

# Minimum 15 shards: ceil(50,000 PUT/s ÷ 3,500/s per prefix) = 15.
variable "s3_shard_count" {
  type    = number
  default = 15
}

variable "github_org" {
  type    = string
  default = "hrs-group"
}

variable "github_repo" {
  type    = string
  default = "platform-app"
}

variable "newrelic_license_key" {
  type      = string
  sensitive = true
  default   = ""
}

# Sample tenants — add more here to provision full team set.
variable "teams" {
  type = map(object({
    quota_cpu    = string
    quota_memory = string
  }))
  default = {
    "team-01" = { quota_cpu = "10", quota_memory = "20Gi" }
    "team-02" = { quota_cpu = "10", quota_memory = "20Gi" }
    "team-03" = { quota_cpu = "10", quota_memory = "20Gi" }
  }
}

variable "terraform_state_bucket" {
  type    = string
  default = "hrs-platform-terraform-state"
}

variable "terraform_state_lock_table" {
  type    = string
  default = "hrs-platform-terraform-locks"
}
