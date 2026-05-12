# Phase 2 — Infrastructure as Code

This phase provisions the complete AWS + Kubernetes platform using Terraform and Kubernetes manifests.

## Directory structure

```
2_infrastructure/
├── terraform/           # AWS resources (EKS, VPC, RDS, S3, IAM, …)
│   ├── backend.tf       # S3 + DynamoDB remote state
│   ├── main.tf          # Provider configuration
│   ├── variables.tf     # All input variables with defaults
│   ├── terraform.tfvars # Environment-specific values (no secrets)
│   ├── versions.tf      # Provider version pins
│   ├── vpc.tf           # VPC, subnets, NAT gateways, security groups, VPC Flow Logs
│   ├── eks.tf           # EKS cluster, node group, add-ons, Cilium, ArgoCD, Kyverno, cert-manager, ESO
│   ├── iam.tf           # All IAM roles: EKS, IRSA per-component and per-tenant, GitHub Actions OIDC
│   ├── rds.tf           # RDS PostgreSQL 16 + RDS Proxy + CloudWatch alarms
│   ├── s3.tf            # Asset bucket (15-shard layout), access logging, KMS
│   ├── ecr.tf           # ECR repositories and lifecycle policies (one per team)
│   ├── secrets_manager.tf # Secrets Manager secrets with KMS encryption
│   ├── karpenter.tf     # Karpenter v1.0 Helm release
│   └── outputs.tf       # All important outputs (cluster endpoint, ECR URLs, role ARNs, …)
└── k8s/                 # Kubernetes manifests applied post-cluster-creation
    ├── namespaces/      # Tenant namespaces with PSS restricted labels
    ├── network-policies/ # Default-deny + allow-list policies per namespace
    ├── rbac/            # ServiceAccounts, Roles, RoleBindings per team
    ├── quotas/          # ResourceQuota + LimitRange per team
    ├── karpenter/       # NodePool + EC2NodeClass (v1.0 API)
    ├── argocd/          # AppProjects, ApplicationSet, Image Updater
    ├── kyverno/         # ClusterPolicies (Audit mode → Enforce after validation)
    ├── cert-manager/    # ClusterIssuers (Let's Encrypt prod + staging), wildcard Certificate
    └── external-secrets/ # ClusterSecretStore + per-tenant ExternalSecrets
```

## Prerequisites

1. AWS CLI configured with admin credentials
2. `terraform >= 1.7`
3. `kubectl`, `helm >= 3`
4. Run **once** before `terraform init`:

```bash
bash scripts/bootstrap.sh
```

This creates the S3 state bucket and DynamoDB lock table. Terraform cannot manage its own backend bucket.

## Deploy

This is a **two-stage apply** because ACM cert validation needs DNS to be delegated
from GoDaddy to Route53 first.

### Stage 1 — Create the Route53 hosted zone

```bash
cd 2_infrastructure/terraform
terraform init

# Create just the hosted zone so we can get the NS records.
TF_VAR_rds_master_password=<password> \
terraform apply -target=aws_route53_zone.platform

# Read the NS records — copy these into GoDaddy.
terraform output route53_nameservers
```

### Stage 2 — Delegate the subdomain in GoDaddy

1. Log into GoDaddy → DNS for `talkit.chat`
2. Add four NS records for the host `platform`, one per nameserver from the output above:
   ```
   Type: NS    Name: platform    Value: ns-xxx.awsdns-xx.com    TTL: 1 hour
   Type: NS    Name: platform    Value: ns-yyy.awsdns-yy.org    TTL: 1 hour
   Type: NS    Name: platform    Value: ns-zzz.awsdns-zz.net    TTL: 1 hour
   Type: NS    Name: platform    Value: ns-www.awsdns-ww.co.uk  TTL: 1 hour
   ```
3. Wait ~5 minutes and verify: `dig NS platform.talkit.chat +short` should return the AWS nameservers.

### Stage 3 — Full apply

```bash
TF_VAR_rds_master_password=<password> \
TF_VAR_newrelic_license_key=<key> \
terraform apply
```

ACM validation will complete in 2-5 minutes once it sees the delegated DNS records.
Everything else (EKS, Helm releases, RDS, ECR, …) is created in this stage.

## Apply Kubernetes manifests

After `terraform apply`, configure kubectl:

```bash
aws eks update-kubeconfig --name hrs-platform --region eu-central-1
```

Then apply manifests in order (dependencies matter):

```bash
kubectl apply -f k8s/namespaces/
kubectl apply -f k8s/network-policies/
kubectl apply -f k8s/rbac/
kubectl apply -f k8s/quotas/
kubectl apply -f k8s/karpenter/
kubectl apply -f k8s/argocd/
kubectl apply -f k8s/kyverno/
kubectl apply -f k8s/cert-manager/
kubectl apply -f k8s/external-secrets/
```

## Add a new team

1. Add an entry to `var.teams` in `terraform.tfvars`
2. Add a namespace block to `k8s/namespaces/namespaces.yaml`
3. Add network policy, RBAC, and quota blocks (copy an existing team's block)
4. Add the team to the ArgoCD ApplicationSet generator list
5. Run `terraform apply` then `kubectl apply -f k8s/`

## Security posture

| Layer | Control | Implementation |
|-------|---------|----------------|
| 1 — Namespace | PSS restricted | `pod-security.kubernetes.io/enforce: restricted` |
| 2 — Network | Default-deny Cilium eBPF | NetworkPolicy per namespace |
| 3 — Identity | RBAC | Namespace-scoped Roles only |
| 4 — Cloud credentials | IRSA | Per-team IAM roles, no node-level keys |
| 5 — Policy | Kyverno | Resource limits, ECR-only images, no NodePort, non-root |

## Key outputs

After `terraform apply`:

```bash
# ECR URLs for CI
terraform output ecr_repositories

# GitHub Actions role ARN — set as repo secret AWS_ROLE_ARN
terraform output github_actions_role_arn

# RDS Proxy endpoint — use in app DATABASE_URL
terraform output rds_proxy_endpoint

# Tenant IRSA role ARNs — annotate ServiceAccounts
terraform output tenant_irsa_role_arns
```
