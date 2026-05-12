# HRS Multi-Tenant Platform — Architecture Design

## Overview

Architecture for the HRS Multi-Tenant Application Platform supporting **20+ engineering teams (250+ engineers)**, scaling to **50+ teams** on AWS EKS.

| | |
|---|---|
| **Version** | 2.1 |
| **Region** | AWS eu-central-1 |
| **Monthly Cost (50 teams)** | ~$966/month (~$19/team; ~$12/team optimised) |
| **Isolation** | 5-layer defense in depth |
| **CD Pattern** | GitOps (ArgoCD + ApplicationSets) |
| **CNI** | Cilium (managed EKS add-on, eBPF) |

---

## Contents

### [ARCHITECTURE.md](./ARCHITECTURE.md)
The complete architecture specification:
- 5-layer defense in depth (Namespace → Cilium NetPol → RBAC → IRSA → Kyverno)
- Storage isolation (RDS schema + RLS, S3 multi-prefix, Secrets Manager ESO)
- GitOps CI/CD flow (GitHub Actions OIDC → ECR → ArgoCD Image Updater → GitOps repo → ArgoCD)
- Security model (Cilium, Kyverno, ESO, cert-manager, KMS, PSS restricted, EKS private endpoint, VPC Flow Logs)
- Cost breakdown (~$966/month at 50-team scale)
- Design trade-offs with rationale (10 decisions)
- Full validation checklist

### [architecture/ARCHITECTURE_DIAGRAM.md](./architecture/ARCHITECTURE_DIAGRAM.md)
Mermaid flowchart showing all components and data flows:
- Traffic: Users → ALB → Tenant Pods
- CI/CD: GitHub Actions (OIDC) → ECR → GitOps Repo → ArgoCD → Namespaces
- Secrets: ESO → Secrets Manager → Pods
- Observability: OTel → New Relic (metrics + traces); Fluent Bit → CloudWatch (logs)

### [architecture/ARCHITECTURE_DIAGRAM.svg](./architecture/ARCHITECTURE_DIAGRAM.svg)
Visual SVG showing the full platform layout with all v2.1 components.

---

## Key Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| CNI | Cilium (managed add-on) | Calico breaks EKS ENI networking; Cilium is AWS-supported with eBPF + L7 policies |
| CD | ArgoCD + ApplicationSets | GitOps drift detection; per-tenant AppProject isolation; scales to 50+ from one template |
| Secrets | ESO + Secrets Manager | Secrets never in etcd; IRSA-scoped; auto-rotation |
| Admission | Kyverno | K8s-native YAML policies; no Rego; enforces resource limits, ECR-only, no NodePort |
| TLS | cert-manager | Auto-renew at scale; no manual certificate management |
| CI auth | OIDC (not stored creds) | `AssumeRoleWithWebIdentity` — zero long-lived credentials in GitHub |
| PSS level | Restricted | Baseline allows hostNetwork/hostPID escalation paths; restricted closes them |
| DB | Shared RDS + Schema + RLS | $100/month vs $25K for per-tenant instances; RLS is DB-engine enforced |

---

## Next Steps

1. ✅ Phase 1: Architecture Design (this directory — complete)
2. → Phase 2: Infrastructure as Code ([2_infrastructure/](../2_infrastructure/))
3. → Phase 3: Observability ([3_observability/](../3_observability/))
4. → Phase 4: Documentation + Runbooks

---

**Version:** 2.1  
**Status:** Ready for Phase 2 implementation
