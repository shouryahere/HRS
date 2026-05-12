# HRS Multi-Tenant Platform Engineering Assessment

A production-grade multi-tenant SaaS platform for **HRS TravelTech** supporting 20+ engineering teams (250+ engineers), scalable to 50+ teams on AWS EKS.

## Status: Complete ✅

All three phases are implemented and committed.

---

## Repository structure

```
.
├── 1_platform_design/                    # Phase 1 — Architecture Design
│   ├── ARCHITECTURE.md                   # Full architecture spec (v2.1)
│   ├── README.md                         # Design overview and decisions
│   └── architecture/
│       ├── ARCHITECTURE_DIAGRAM.md       # Mermaid architecture diagram
│       └── ARCHITECTURE_DIAGRAM.svg      # SVG architecture diagram
│
├── 2_infrastructure/                     # Phase 2 — Infrastructure as Code
│   ├── terraform/
│   │   ├── backend.tf                    # S3 + DynamoDB remote state
│   │   ├── main.tf                       # Provider configuration
│   │   ├── variables.tf                  # Input variables
│   │   ├── terraform.tfvars              # Environment values (no secrets)
│   │   ├── versions.tf                   # Provider version pins
│   │   ├── vpc.tf                        # VPC, subnets, NAT GWs, Flow Logs, VPC endpoints
│   │   ├── eks.tf                        # EKS 1.32, Cilium, ArgoCD, Kyverno, cert-manager, ESO
│   │   ├── iam.tf                        # All IAM/IRSA roles (cluster, nodes, per-component, per-tenant)
│   │   ├── rds.tf                        # PostgreSQL 16 Multi-AZ + RDS Proxy
│   │   ├── s3.tf                         # Asset bucket (15-shard), KMS, access logs
│   │   ├── ecr.tf                        # ECR repos per team, lifecycle policies
│   │   ├── secrets_manager.tf            # Secrets Manager + KMS key
│   │   ├── karpenter.tf                  # Karpenter v1.0, Spot interruption SQS/EventBridge
│   │   └── outputs.tf                    # Cluster endpoint, ECR URLs, role ARNs
│   │
│   ├── k8s/
│   │   ├── namespaces/                   # Tenant namespaces (PSS restricted)
│   │   ├── network-policies/             # Default-deny + allow-list (tenant + platform)
│   │   ├── rbac/                         # ServiceAccounts, Roles, RoleBindings per team
│   │   ├── quotas/                       # ResourceQuota + LimitRange per team
│   │   ├── karpenter/                    # NodePool + EC2NodeClass (v1.0 API)
│   │   ├── argocd/                       # AppProjects, ApplicationSet, Image Updater
│   │   ├── kyverno/                      # ClusterPolicies (Audit → Enforce)
│   │   ├── cert-manager/                 # ClusterIssuers (Let's Encrypt), wildcard cert
│   │   └── external-secrets/            # ClusterSecretStore + per-tenant ExternalSecrets
│   │
│   └── README.md                         # Deployment guide
│
├── 3_observability/                      # Phase 3 — Observability
│   ├── otel/otel-collector.yaml          # OTel Collector DaemonSet → New Relic
│   ├── fluent-bit/fluent-bit.yaml        # Fluent Bit DaemonSet → CloudWatch
│   ├── sample-app/                       # Python/FastAPI app with OTel instrumentation
│   ├── dashboards/                       # New Relic dashboard definitions (JSON)
│   │   ├── platform-overview.json        # Cluster health, SLO burn rate
│   │   ├── per-tenant.json               # Per-team service health, DB latency
│   │   └── dora-metrics.json             # Deployment frequency, lead time, MTTR
│   ├── alerts/alert-rules.yaml           # SLO, latency, CrashLoop, node memory, TLS, RDS
│   └── README.md                         # Observability setup guide
│
├── .github/workflows/ci.yml              # CI: OIDC auth, Trivy scan, ECR push, GitOps write-back
├── scripts/bootstrap.sh                  # Run ONCE before terraform init (creates S3 + DynamoDB)
├── DESIGN_PLAN_new.md                    # Master design plan (v2.1)
└── devops-engineer-assessment.pdf        # Original assessment
```

---

## Quick start

### Prerequisites
- AWS CLI with admin credentials
- Terraform ≥ 1.7, kubectl, helm ≥ 3

### 1. Bootstrap remote state (once only)

```bash
bash scripts/bootstrap.sh
```

### 2. Deploy infrastructure

```bash
cd 2_infrastructure/terraform
terraform init

TF_VAR_rds_master_password=<password> \
TF_VAR_newrelic_license_key=<key> \
terraform apply
```

### 3. Apply Kubernetes manifests

```bash
aws eks update-kubeconfig --name hrs-platform --region eu-central-1

kubectl apply -f 2_infrastructure/k8s/namespaces/
kubectl apply -f 2_infrastructure/k8s/network-policies/
kubectl apply -f 2_infrastructure/k8s/rbac/
kubectl apply -f 2_infrastructure/k8s/quotas/
kubectl apply -f 2_infrastructure/k8s/karpenter/
kubectl apply -f 2_infrastructure/k8s/argocd/
kubectl apply -f 2_infrastructure/k8s/kyverno/
kubectl apply -f 2_infrastructure/k8s/cert-manager/
kubectl apply -f 2_infrastructure/k8s/external-secrets/
```

### 4. Deploy observability

```bash
kubectl apply -f 3_observability/otel/otel-collector.yaml
kubectl apply -f 3_observability/fluent-bit/fluent-bit.yaml
```

---

## Architecture highlights

### 5-layer tenant isolation

| Layer | Control | Implementation |
|-------|---------|----------------|
| 1 — Namespace | Pod Security Standards (restricted) | `pod-security.kubernetes.io/enforce: restricted` |
| 2 — Network | Cilium eBPF default-deny | `NetworkPolicy` per namespace |
| 3 — Identity | RBAC | Namespace-scoped Roles only — no cluster-wide access |
| 4 — Cloud credentials | IRSA | Per-team IAM roles scoped to `hrs/<team>/*` paths |
| 5 — Policy | Kyverno | Resource limits, ECR-only images, no NodePort, non-root |

### Key design decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tenancy model | Namespace-per-team | Cost efficiency; strong isolation via 5 layers |
| CNI | Cilium (ENI chaining) | eBPF L7 policies + Hubble observability; compatible with VPC CNI |
| GitOps | ArgoCD + Image Updater | Per-team AppProjects; OIDC→ECR→Git tag loop; selfHeal |
| Secrets | ESO + Secrets Manager | Values never touch etcd; IRSA-scoped per team |
| DB | RDS + Proxy + RLS | Connection pooling (1000 clients); row-level isolation engine-enforced |
| Autoscaling | Karpenter v1.0 | NodePool + EC2NodeClass; Spot + on-demand; 30s consolidation |
| TLS | ACM (ALB) + Let's Encrypt (in-cluster) | DNS-01 via Route53 IRSA; wildcard `*.platform.talkit.chat` |
| CI auth | GitHub Actions OIDC | `AssumeRoleWithWebIdentity` — zero stored AWS credentials |

### Cost

| Scenario | Monthly | Per team (50 teams) |
|----------|---------|---------------------|
| EKS 1.32 (extended support) | ~$1,379 | ~$28 |
| After upgrade to EKS 1.33 | ~$941 | ~$19 |

---

## Adding a new team

1. Add an entry to `teams` in `2_infrastructure/terraform/terraform.tfvars`
2. Add a namespace block to `2_infrastructure/k8s/namespaces/namespaces.yaml`
3. Duplicate a team block in `network-policies/`, `rbac/`, and `quotas/`
4. Add the team to the ArgoCD ApplicationSet list generator
5. `terraform apply` → `kubectl apply -f 2_infrastructure/k8s/`

The team gets: namespace + PSS, network policies, RBAC, ResourceQuota, IRSA role, ECR repo, ESO secret path, ArgoCD AppProject + Application — all scoped exclusively to their namespace.
