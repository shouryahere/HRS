output "cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "EKS cluster name"
}

output "cluster_endpoint" {
  value       = aws_eks_cluster.main.endpoint
  description = "EKS API server endpoint (private)"
}

output "cluster_ca_certificate" {
  value       = aws_eks_cluster.main.certificate_authority[0].data
  description = "EKS cluster CA certificate (base64)"
  sensitive   = true
}

output "oidc_issuer" {
  value       = local.oidc_issuer
  description = "OIDC issuer URL (without https://) for IRSA trust policies"
}

output "oidc_arn" {
  value       = local.oidc_arn
  description = "OIDC provider ARN"
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "Private subnet IDs (EKS nodes, RDS)"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnet IDs (ALB, NAT gateways)"
}

output "rds_proxy_endpoint" {
  value       = aws_db_proxy.main.endpoint
  description = "RDS Proxy endpoint — use this in application DB_URL"
}

output "rds_instance_endpoint" {
  value       = aws_db_instance.main.endpoint
  description = "RDS direct endpoint (admin/migration use only)"
}

output "s3_assets_bucket" {
  value       = aws_s3_bucket.assets.bucket
  description = "S3 assets bucket name"
}

output "ecr_repositories" {
  value       = { for k, v in aws_ecr_repository.tenant : k => v.repository_url }
  description = "ECR repository URLs keyed by team name"
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_ci.arn
  description = "IAM role ARN for GitHub Actions OIDC — set in repo secrets as AWS_ROLE_ARN"
}

output "tenant_irsa_role_arns" {
  value       = { for k, v in aws_iam_role.tenant : k => v.arn }
  description = "Per-tenant IRSA role ARNs keyed by team name"
}

output "karpenter_interruption_queue" {
  value       = aws_sqs_queue.karpenter_interruption.name
  description = "Karpenter Spot interruption SQS queue name"
}

output "kms_key_s3_arn" {
  value       = aws_kms_key.s3.arn
  description = "KMS key ARN for S3 encryption"
}

output "kms_key_secrets_arn" {
  value       = aws_kms_key.secrets.arn
  description = "KMS key ARN for Secrets Manager encryption"
}

output "aws_account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "AWS account ID"
}

output "aws_region" {
  value       = var.aws_region
  description = "AWS region"
}
