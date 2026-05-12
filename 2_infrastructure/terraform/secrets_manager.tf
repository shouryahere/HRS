# ── KMS Key for Secrets Manager ───────────────────────────────────────────────
resource "aws_kms_key" "secrets" {
  description             = "${var.cluster_name} Secrets Manager encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags                    = { Name = "${var.cluster_name}-secrets-key" }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ── Per-Tenant Secret Placeholders ───────────────────────────────────────────
# Secrets are created here as shells; actual values are written by the onboarding
# pipeline (or manually for initial setup). ESO reads these at deploy time —
# values are never stored in etcd.
resource "aws_secretsmanager_secret" "tenant_db_url" {
  for_each   = var.teams
  name       = "hrs/${each.key}/db-url"
  description = "PostgreSQL connection URL for ${each.key} (injected by ESO)"
  kms_key_id = aws_kms_key.secrets.arn

  recovery_window_in_days = 7

  tags = { Team = each.key }
}

resource "aws_secretsmanager_secret" "tenant_api_key" {
  for_each    = var.teams
  name        = "hrs/${each.key}/api-key"
  description = "Service API key for ${each.key}"
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = 7

  tags = { Team = each.key }
}

# ── Platform-Level Secrets ────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "newrelic_license" {
  name        = "hrs/platform/newrelic-license-key"
  description = "New Relic ingest license key for OTel collector"
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "newrelic_license" {
  count     = var.newrelic_license_key != "" ? 1 : 0
  secret_id = aws_secretsmanager_secret.newrelic_license.id
  secret_string = var.newrelic_license_key
}

resource "aws_secretsmanager_secret" "argocd_admin" {
  name        = "hrs/platform/argocd-admin-password"
  description = "ArgoCD initial admin password (bcrypt hash)"
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = 7
}
