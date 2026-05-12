# HRS Multi-Tenant Platform — Architecture Specification

**Version:** 2.1  
**Region:** AWS eu-central-1  
**Teams Supported:** 20+ (scaling to 50+)  
**Engineering Population:** 250+ engineers  
**Monthly Cost (50-team scale):** ~$1,379/month on EKS 1.32 (~$28/team) → ~$941/month after upgrade to EKS 1.33 (~$19/team; ~$12/team optimised)

---

## 1. Architecture Overview

### High-Level Design

```
┌──────────────────────────────────────────────────────────────────────┐
│               AWS eu-central-1  VPC (10.0.0.0/16)                   │
│                     VPC Flow Logs enabled                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │     Internet-Facing ALB  (cert-manager TLS, HTTPS 443)        │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                              │                                       │
│  ┌───────────────────────────▼────────────────────────────────────┐  │
│  │   EKS Cluster  —  Private API Endpoint  —  Cilium CNI (eBPF)  │  │
│  │                                                                 │  │
│  │  Platform Namespace  (default-deny network policy):            │  │
│  │  • ArgoCD + ApplicationSets + AppProjects   (GitOps CD)        │  │
│  │  • ArgoCD Image Updater                     (tag automation)   │  │
│  │  • Kyverno ClusterPolicies                  (admission control)│  │
│  │  • cert-manager                             (TLS lifecycle)    │  │
│  │  • External Secrets Operator (ESO)          (secrets delivery) │  │
│  │  • OpenTelemetry Collector DaemonSet        (metrics + traces) │  │
│  │  • Fluent Bit DaemonSet                     (log aggregation)  │  │
│  │                                                                 │  │
│  │  Tenant Namespaces  team-01 … team-N  (Terraform for_each):   │  │
│  │  • PSS restricted enforced at namespace level                  │  │
│  │  • Cilium NetworkPolicy  (default-deny + explicit allow rules) │  │
│  │  • RBAC Role + RoleBinding  (namespace-scoped)                 │  │
│  │  • Kyverno policies enforced  (resource limits, ECR-only)      │  │
│  │  • IRSA ServiceAccount  (per-tenant IAM role)                  │  │
│  │  • ResourceQuota + LimitRange  (noisy-neighbor prevention)     │  │
│  │  • ExternalSecret CRD  (ESO-managed secrets)                   │  │
│  │  • ArgoCD Application  (scoped to own AppProject only)         │  │
│  │                                                                 │  │
│  │  Node Group  t3.medium  2–10 nodes  Karpenter autoscaling     │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  Shared Infrastructure  (VPC endpoints for S3 + ECR)          │  │
│  │  • RDS PostgreSQL Multi-AZ  (schema isolation + RLS)           │  │
│  │  • RDS Proxy  (1000 pooled connections)                        │  │
│  │  • S3  (multi-prefix sharding, VPC endpoint)                   │  │
│  │  • ECR  (per-tenant repos, VPC endpoint, Enhanced Scanning)    │  │
│  │  • AWS Secrets Manager  (hrs/team-XX/ path hierarchy)          │  │
│  │  • GitHub Actions  (CI: build → Trivy → ECR push, OIDC auth)  │  │
│  │  • GitOps Repo  (platform-gitops, ArgoCD watches this)         │  │
│  │  • OpenTelemetry → New Relic  (metrics, traces, DORA, SLOs)    │  │
│  │  • Fluent Bit → CloudWatch Logs  (pod logs + VPC Flow Logs)    │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Component Summary

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Container Orchestration | AWS EKS 1.32 (extended support) | Managed Kubernetes; upgrade path → 1.33 → 1.34 within 2026 |
| Networking | AWS VPC + ALB | Public/private subnets; HTTPS ingress |
| CNI | Cilium (managed EKS add-on, eBPF) | L3/L4/L7 network policies; Hubble observability |
| Multi-Tenancy | Kubernetes Namespaces | Logical tenant isolation unit |
| GitOps CD | ArgoCD + ApplicationSets | Declarative CD; per-tenant AppProject; drift correction |
| CI Pipeline | GitHub Actions (OIDC auth) | Build, Trivy scan, push to ECR; no stored credentials |
| Image Tag Automation | ArgoCD Image Updater | Polls ECR → commits tag to GitOps repo → ArgoCD syncs |
| Admission Control | Kyverno ClusterPolicies | Enforce resource limits, ECR-only images, no NodePort |
| TLS Management | cert-manager | Auto-provision/renew wildcard + per-tenant certs |
| Secrets Management | ESO + AWS Secrets Manager | Secrets never in etcd; IRSA-scoped; auto-rotation |
| Identity & Access | RBAC + IRSA | Kubernetes RBAC + IAM Roles for Service Accounts |
| Data Storage | RDS PostgreSQL + RLS | Multi-AZ; schema + Row-Level Security per tenant |
| Connection Pooling | RDS Proxy | 1000 pooled connections for 50+ tenants |
| Artifact Storage | S3 + ECR | Multi-prefix sharding; per-tenant ECR repos |
| Secrets Encryption | AWS KMS | Encrypts etcd at rest + Secrets Manager values |
| Log Aggregation | Fluent Bit DaemonSet | Pod stdout/stderr → CloudWatch with `tenant_id` |
| Metrics + Traces | OpenTelemetry + New Relic | Tenant-isolated pipelines; DORA + SLO dashboards |
| Node Autoscaling | Karpenter | Bin-packing; spot instance support; fast scale-up |
| Resource Governance | ResourceQuota + LimitRange | Per-namespace limits; Kyverno enforces pod-level |
| IaC State | Terraform + S3 backend | Remote state with DynamoDB locking |
| Network Forensics | VPC Flow Logs | All ENI traffic → CloudWatch Logs |
| Audit Trail | CloudTrail + EKS Audit Logs | All AWS API calls + Kubernetes API calls logged |

---

## 2. Multi-Tenancy Isolation Strategy

### 2.1 Five-Layer Defense in Depth

**Layer 1 — Namespace Isolation (Logical)**

Each tenant has a dedicated Kubernetes namespace. Resource names are scoped. PSS restricted labels applied at namespace level.

- Limitation: not kernel-isolated (node exploit = all tenants at risk)
- Mitigation: PSS restricted + Kyverno + audit logging (see Layers 2–5)

**Layer 2 — Network Policies (Cilium eBPF — L3/L4/L7)**

Default-deny on all tenant namespaces. Explicit allow rules for ALB ingress, DNS egress, and RDS access only.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: team-01
spec:
  endpointSelector: {}
  ingress: []
  egress: []
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-ingress-from-alb
  namespace: team-01
spec:
  endpointSelector: {}
  ingress:
    - fromEntities:
        - world
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```

**Why Cilium, not Calico:** AWS EKS uses VPC CNI (ENI-based pod networking). Installing Calico as a full CNI replacement overwrites ENI networking and is unsupported by AWS. Cilium is an AWS-supported managed EKS add-on that chains onto VPC CNI — pods keep VPC-native IPs while gaining eBPF-native network policies and L7 HTTP-aware rules. Cilium Hubble provides network flow observability per-namespace.

**Layer 3 — RBAC (Kubernetes API Server)**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-developer
  namespace: team-01
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-01-developers
  namespace: team-01
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: tenant-developer
subjects:
- kind: Group
  name: "team-01-developers@talkit.chat"
```

ArgoCD AppProjects enforce that Tenant-A's ArgoCD application can only deploy to Tenant-A's namespace — CD-layer isolation in addition to K8s RBAC.

**Layer 4 — IAM Roles (AWS Cloud Provider — IRSA)**

Each tenant workload has a dedicated IAM role via IRSA. Access is scoped to the tenant's own resources only:

```terraform
resource "aws_iam_role" "tenant_role" {
  for_each = local.teams
  name     = "${each.key}-workload-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:${each.key}:${each.key}-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "tenant_s3" {
  for_each = local.teams
  name     = "${each.key}-s3-access"
  role     = aws_iam_role.tenant_role[each.key].id
  policy   = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::hrs-artifacts",
        "arn:aws:s3:::hrs-artifacts/shard-*/tenant-${each.key}/*"
      ]
    }]
  })
}
```

**Layer 5 — Admission Control (Kyverno ClusterPolicies)**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  # Start with Audit mode; switch to Enforce after 24-48h validation (see rollout note below)
  validationFailureAction: Audit
  rules:
  - name: check-limits
    match:
      resources:
        kinds: [Pod]
    validate:
      message: "CPU and memory limits are required on all pods."
      pattern:
        spec:
          containers:
          - resources:
              limits:
                cpu: "?*"
                memory: "?*"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ecr-only-images
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-registry
    match:
      resources:
        kinds: [Pod]
    validate:
      message: "Images must be from ECR only (no public registries)."
      pattern:
        spec:
          containers:
          - image: "*.dkr.ecr.eu-central-1.amazonaws.com/*"
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-nodeport
spec:
  validationFailureAction: Enforce
  rules:
  - name: deny-nodeport
    match:
      resources:
        kinds: [Service]
    validate:
      message: "NodePort and LoadBalancer services are not allowed. Use ALB Ingress."
      pattern:
        spec:
          =(type): "!NodePort & !LoadBalancer"
```

---

### 2.2 Additional Security Controls

**Pod Security Standards (restricted):** Applied at namespace level via labels. Enforces: no root user, no privileged containers, no `hostPath` mounts, no privilege escalation, read-only root filesystem required. System namespaces use `baseline` with documented exceptions.

**External Secrets Operator:** Application secrets fetched from AWS Secrets Manager at deploy time via ESO `ExternalSecret` CRDs. Secrets never committed to Git and never stored permanently in etcd. Short-lived K8s Secrets created in the tenant namespace, scoped by IRSA role.

**KMS Encryption:** EKS etcd encrypted at rest. Secrets Manager values encrypted with KMS.

**EKS Private API Endpoint:** `endpoint_public_access = false`. The Kubernetes API server is only accessible from within the VPC. Operators access via bastion host or VPN. Eliminates the public-internet attack surface on the cluster control plane.

**Platform Namespace Network Policies:** ArgoCD, Kyverno, cert-manager, and ESO namespaces have default-deny network policies. Only the ALB (ArgoCD UI) and the EKS API server (webhook calls for Kyverno/cert-manager) have explicit ingress allow rules. Tenant pods cannot reach platform components.

**VPC Flow Logs:** Enabled on all VPC ENIs. Network-layer traffic captured to CloudWatch Logs for forensics and compliance — complements Cilium Hubble (pod-level) with VPC-level visibility.

**Container Image Scanning:** Trivy runs in GitHub Actions on every image build before ECR push. Builds with HIGH or CRITICAL CVEs are blocked. ECR Enhanced Scanning provides continuous post-push CVE monitoring.

**GitHub Actions OIDC:** CI pipeline authenticates to AWS via OIDC federation (`AssumeRoleWithWebIdentity`). No long-lived credentials stored in GitHub Secrets.

**Kyverno rollout:** Policies are deployed with `validationFailureAction: Audit` initially (violations logged, workloads allowed). After 24–48h with no unexpected violations observed, switch to `Enforce`. Skipping the Audit phase risks blocking legitimate workloads on day one.

**Fluent Bit IRSA:** Fluent Bit DaemonSet runs under a ServiceAccount with an IRSA role granting `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, and `logs:DescribeLogStreams` on `arn:aws:logs:eu-central-1:ACCOUNT:log-group:hrs-platform-*`. Without this, Fluent Bit silently fails to deliver logs.

**ArgoCD Image Updater IRSA:** Image Updater ServiceAccount has an IRSA role granting `ecr:DescribeImages`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, and `ecr:GetAuthorizationToken`. Without this, Image Updater cannot poll ECR and the CI→CD loop is broken.

**cert-manager IRSA:** cert-manager ServiceAccount has an IRSA role granting `route53:ChangeResourceRecordSets`, `route53:ListHostedZones`, and `route53:ListResourceRecordSets` to complete DNS-01 ACME challenges for Let's Encrypt certificate issuance.

**TLS architecture (two layers):**
- **ALB TLS:** ACM certificate (`*.platform.talkit.chat`) attached to the ALB listener in Terraform. Free, AWS-managed, auto-renewed. cert-manager is not involved.
- **In-cluster TLS:** cert-manager with `ClusterIssuer` backed by Let's Encrypt DNS-01 via Route53. Wildcard cert `*.platform.talkit.chat`. Public domain required — Let's Encrypt does not issue certs for `.internal` TLDs.

---

### 2.3 Storage Isolation

**RDS PostgreSQL — Schema + Row-Level Security:**

```sql
-- Per-tenant schema
CREATE SCHEMA team_01 AUTHORIZATION team_01_user;

-- Enable RLS on shared tables
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE events FORCE ROW LEVEL SECURITY;

-- Policy: each tenant sees only their own rows
-- DB-engine enforced — applies even if application has SQL injection
CREATE POLICY tenant_isolation ON events
  USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

RLS is DB-engine enforced. Even if a tenant's application has a SQL injection vulnerability, RLS ensures queries only return rows matching the current session's `app.tenant_id`. Trade-off: ~2–5ms query planning overhead — acceptable at this scale.

**S3 — Multi-Prefix Sharding:**

S3 limits: 3,500 PUT/s and 5,500 GET/s per prefix. At 50K PUT/s target for 50 teams:

**Shard count:** ⌈50,000 ÷ 3,500⌉ = **15 shards minimum**. Encoded in Terraform as `locals.s3_shard_count = 15`. Tenants are assigned to shards via consistent hashing on team-ID so each shard serves a stable subset of tenants.

```
s3://hrs-artifacts/
├── shard-00/team-01/    # consistent hash of "team-01" → shard 0
├── shard-01/team-02/
├── shard-02/team-03/
...
├── shard-14/team-N/
```

IAM bucket policy enforces prefix-level access control via IRSA. S3 VPC endpoint routes all traffic within VPC — no internet egress charges for artifact traffic.

**AWS Secrets Manager:**

Hierarchical path: `hrs/team-01/db-password`, `hrs/team-01/api-key`, ...

ESO `ExternalSecret` CRD in each tenant namespace fetches secrets at deploy time. IAM resource policy on each secret restricts access to the tenant's IRSA role only.

---

## 3. Scalability Strategy (20 → 50+ Teams)

### 3.1 Namespace Provisioning (Terraform for_each)

```terraform
locals {
  teams = {
    "team-01" = { quota_cpu = "10", quota_memory = "20Gi" }
    "team-02" = { quota_cpu = "10", quota_memory = "20Gi" }
    # Add new teams here — single terraform apply provisions everything
  }
}

resource "kubernetes_namespace" "tenant" {
  for_each = local.teams
  metadata {
    name = each.key
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "team"                               = each.key
    }
  }
}
```

Adding 30 new teams = update `locals.teams` map + `terraform apply`. All namespaces, RBAC, network policies, and resource quotas are provisioned automatically.

### 3.2 GitOps at Scale (ArgoCD ApplicationSet)

One ApplicationSet generates one ArgoCD Application per team. Each Application is scoped to its team's AppProject — Tenant-A's ArgoCD application cannot target Tenant-B's namespace.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-applications
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - team: team-01
          - team: team-02
  template:
    metadata:
      name: "{{team}}-app"
    spec:
      project: "{{team}}"
      source:
        repoURL: https://github.com/hrs-group/platform-gitops
        path: "tenants/{{team}}"
        targetRevision: HEAD
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{team}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

### 3.3 Horizontal Scaling Table

| Component | Scaling Method | At 50+ Teams |
|-----------|-----------------|-------------|
| Namespaces | Terraform `for_each` | 50+ (automated) |
| ArgoCD Apps | ApplicationSet template | 50+ (1 template → N apps) |
| Pods | HPA | 500+ (2–10 per team) |
| Nodes | Karpenter | 20–30 (auto-scaled) |
| RDS Connections | RDS Proxy | 1000+ pooled |
| S3 Requests | Multi-prefix sharding | 50K req/s |
| Secrets | ESO + path hierarchy | 500+ (linear cost) |

---

## 4. Security Model

### 4.1 Threat Model

| Threat | Attack Vector | Mitigation |
|--------|--------------|-----------|
| Data exfiltration | SQL injection + schema bypass | Prepared statements + RLS + RDS IAM auth |
| Cross-tenant network access | Direct pod-to-pod connection | Cilium default-deny + L7 policies |
| Resource starvation | CPU/memory hogging | ResourceQuota + LimitRange + Kyverno |
| Privilege escalation | Node exploit → root container | PSS restricted + Kyverno + audit logging |
| IAM role assumption | Forge service account token | IRSA OIDC validation + STS condition keys |
| Secret exposure | Read etcd directly | KMS encryption + ESO (secrets not in etcd) |
| Supply chain attack | Malicious public image | Kyverno ECR-only + Trivy CI gate + ECR scanning |
| CI credential theft | Stolen GitHub secret | OIDC federation — no stored credentials |
| Control plane access | Public EKS API endpoint | Private endpoint only (`endpoint_public_access = false`) |
| Cross-tenant metric leakage | Metrics visible in wrong dashboard | OTel `tenant_id` processor + namespace filter |

### 4.2 Audit Logging

All API access audited via:
- **EKS Audit Logs** → CloudWatch Logs (Kubernetes API: create/update/delete on secrets and deployments)
- **CloudTrail** → all AWS API calls (S3, IAM, RDS, Secrets Manager, EKS)
- **VPC Flow Logs** → all network-layer traffic on VPC ENIs
- **Cilium Hubble** → pod-level network flow visibility per namespace

---

## 5. CI/CD — GitOps Flow

```
GitHub PR merge
      │
      ▼
GitHub Actions (CI)
  1. docker build
  2. trivy scan --severity HIGH,CRITICAL (fail on findings)
  3. docker push → ECR (OIDC-authenticated, no stored credentials)
  4. git commit image tag → platform-gitops/tenants/team-XX/
      │
      ▼
ArgoCD Image Updater (alternatively: step 4 via Image Updater polling ECR)
      │
      ▼
ArgoCD watches platform-gitops HEAD
  • per-tenant AppProject scoping enforced
  • selfHeal: true → corrects manual kubectl changes
  • prune: true → removes resources deleted from Git
      │
      ▼
Namespace reconciled (team-XX)
```

---

## 6. Cost Estimation (AWS eu-central-1 — 50-team scale)

| Component | Monthly Cost |
|-----------|-------------|
| EKS Control Plane | $73 |
| EKS Extended Support (1.32) | $438 (see note) |
| EC2 Nodes (t3.medium, avg 6) | $180 |
| RDS PostgreSQL Multi-AZ | $100 |
| RDS Proxy | $11 |
| ALB | $50 |
| NAT Gateway × 3 | $70 |
| S3 + ECR VPC Endpoints | $14 |
| S3 Storage (100GB) | $3 |
| ECR Storage (100GB) | $10 |
| Data Transfer (internet egress ~500GB) | $75 |
| AWS Secrets Manager (500 secrets) | $200 |
| CloudWatch Logs (100GB) | $50 |
| VPC Flow Logs (~50GB) | $25 |
| KMS | $15 |
| CloudTrail | $10 |
| New Relic (Starter) | $50 |
| Misc (Route53 hosted zone, RDS snapshots) | $30 |
| **TOTAL on EKS 1.32 (now, incl. extended support)** | **~$1,379/month (~$28/team)** |
| **TOTAL after upgrade to EKS 1.33 (target Q3 2026)** | **~$941/month (~$19/team)** |
| **Optimised post-upgrade (RIs + Spot)** | **~$12/team** |

> **EKS version note:** Kubernetes 1.29 (previously specified) is EOL on EKS as of February 2026. The recommended version for a new cluster in May 2026 is **1.32** — most mature ecosystem support for Cilium 1.15+, Karpenter v1.0, ArgoCD 2.10+, and Kyverno 1.12+. EKS 1.32 is in extended support mode at $0.60/cluster/hour (~$438/month). Upgrade path: 1.32 → 1.33 (by June 2026) → 1.34 (by October 2026), returning to standard support and eliminating the extended support cost.

---

## 7. Design Trade-offs

| Decision | Choice | Rationale | Trade-off |
|----------|--------|-----------|-----------|
| Cluster topology | Shared cluster (namespace-isolated) | 18× cheaper vs dedicated clusters | Requires rigorous 5-layer isolation |
| CNI | Cilium (managed EKS add-on) | AWS-supported; eBPF; L7-aware; Hubble | Newer than Calico, but battle-tested at scale |
| CD pattern | ArgoCD + ApplicationSets | GitOps: drift detection, self-heal, per-tenant AppProject isolation | ArgoCD operator to manage |
| Secrets | ESO + Secrets Manager | Secrets never in etcd; auto-rotation; IRSA-scoped | $0.40/secret/month; $200/month at 50 teams |
| Admission control | Kyverno | K8s-native YAML policies; no Rego language needed | Less battle-tested than OPA at very large scale |
| TLS | cert-manager | Auto-renew; scales to 50+ ingresses | cert-manager operator to manage |
| Database | Shared RDS + Schema + RLS | $100/month vs $25K for per-tenant instances | Shared IOPS; RLS adds ~2–5ms overhead |
| Node autoscaling | Karpenter | Faster scale-up; better bin-packing; spot support | Requires dedicated IAM + SQS setup |
| PSS level | Restricted (not Baseline) | Baseline allows hostNetwork, hostPID escalation paths | Legacy apps may need adjustment |
| CI auth | OIDC (not stored credentials) | No long-lived secrets in GitHub | OIDC provider resource in Terraform required |

---

## 8. Known Limitations

| Limitation | Mitigation (now) | Upgrade Path (future) |
|-----------|------------------|-----------------------|
| Namespace isolation (not kernel-level) | PSS restricted + Kyverno + audit | vCluster (virtual clusters per team) |
| Shared RDS (IOPS noisy-neighbour risk) | RDS Proxy + ResourceQuota | Per-tenant RDS or Aurora Serverless v2 |
| No mTLS between workloads | Cilium L7 policies restrict communication | Cilium service mesh (built-in mTLS) or Istio |
| Single region | Multi-AZ within region | Multi-region active-passive (eu-central-1 + eu-west-1) |
| Namespace isolation (not gVisor) | PSS restricted removes major attack surface | gVisor runtime for sensitive workloads |

---

## 9. Validation Checklist

### Isolation Tests
- [ ] Tenant-A pod cannot reach Tenant-B pod (Cilium policy blocks, Hubble records)
- [ ] Cilium L7 policy blocks HTTP `POST /admin` from unauthorized tenant
- [ ] Tenant-A user cannot list Tenant-B pods (API returns 403)
- [ ] Tenant-A ArgoCD app cannot target Tenant-B namespace (AppProject rejects)
- [ ] Tenant-A IAM role cannot read Tenant-B S3 prefix (AWS returns 403)
- [ ] Tenant-A ESO cannot read `hrs/team-b/*` in Secrets Manager (IAM returns 403)
- [ ] RDS RLS returns empty rows for cross-tenant query (not an error — expected)
- [ ] Tenant pod cannot reach ArgoCD/Kyverno/cert-manager/ESO services

### Admission Control Tests
- [ ] Pod without CPU/memory limits is rejected at admission (Kyverno)
- [ ] Pod referencing `docker.io/nginx:latest` is rejected (Kyverno ECR-only)
- [ ] Service of type NodePort is rejected (Kyverno)
- [ ] Pod running as root is rejected (PSS restricted)
- [ ] Pod requesting `allowPrivilegeEscalation: true` is rejected (PSS restricted)

### Security Tests
- [ ] GitHub Actions workflow authenticates via OIDC (no secrets in CI log)
- [ ] `kubectl` from outside VPC fails (EKS private endpoint)
- [ ] Image with known CVE fails Trivy step and blocks ECR push
- [ ] ArgoCD self-heals within 3 minutes after manual `kubectl delete deployment`
- [ ] VPC Flow Log entry shows REJECT for cross-tenant network attempt

### Observability Tests
- [ ] OTel metrics in New Relic carry `tenant_id` label
- [ ] Tenant-A metrics not visible on Tenant-B's New Relic dashboard
- [ ] Fluent Bit logs in CloudWatch carry `tenant_id` field
- [ ] DORA dashboard shows deploy frequency per team
- [ ] SLO alert fires when error rate exceeds 0.1%

### Scalability Tests
- [ ] Add 30 new teams: update Terraform + ArgoCD → provisioned < 5 minutes
- [ ] Karpenter scales nodes within 60 seconds under load
- [ ] RDS Proxy pools 50+ tenant connections without exhaustion
- [ ] S3 throughput: 50K req/s across multi-prefix shards (no throttling)

---

**Document Version:** 2.1  
**Last Updated:** May 12, 2026  
**Status:** Ready for Implementation  
**See also:** [DESIGN_PLAN_new.md](../DESIGN_PLAN_new.md) — master implementation plan
