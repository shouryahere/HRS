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

output "acm_certificate_arn" {
  value       = aws_acm_certificate_validation.platform.certificate_arn
  description = "ACM certificate ARN (post-validation) for the wildcard *.platform.talkit.chat — annotate on tenant Ingress objects"
}

output "route53_zone_id" {
  value       = aws_route53_zone.platform.zone_id
  description = "Route53 hosted zone ID for the platform subdomain"
}

output "route53_nameservers" {
  value       = aws_route53_zone.platform.name_servers
  description = "Nameservers — copy these into GoDaddy as NS records for the 'platform' subdomain of talkit.chat to delegate DNS to Route53"
}

output "aws_lb_controller_role_arn" {
  value       = aws_iam_role.aws_lb_controller.arn
  description = "AWS Load Balancer Controller IRSA role ARN"
}

output "fluent_bit_role_arn" {
  value       = aws_iam_role.fluent_bit.arn
  description = "Fluent Bit IRSA role ARN — annotate on the fluent-bit ServiceAccount in the monitoring namespace"
}

output "argocd_image_updater_role_arn" {
  value       = aws_iam_role.argocd_image_updater.arn
  description = "ArgoCD Image Updater IRSA role ARN — annotate on its ServiceAccount in the argocd namespace"
}

output "rds_master_secret_arn" {
  value       = aws_secretsmanager_secret.rds_master.arn
  description = "Secrets Manager ARN of the RDS master credentials secret"
}
