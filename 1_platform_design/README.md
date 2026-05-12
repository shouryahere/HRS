# HRS Multi-Tenant Platform - Architecture Design

## Overview

This directory contains the complete architecture design for the **HRS Multi-Tenant Application Platform** designed to support **20+ engineering teams (250+ engineers)** with scalability to **50+ teams**.

**Key Metrics:**
- **Target Teams:** 20 → 50+
- **Engineering Population:** 250+ engineers
- **Region:** AWS eu-central-1
- **Monthly Cost:** ~$911 (infrastructure) = $18.22/team at 50-team scale
- **Isolation Level:** 95% (namespace + network policies + IAM roles + KMS encryption)

## Contents

### 1. [ARCHITECTURE.md](./ARCHITECTURE.md)
**Comprehensive design document covering:**
- Executive summary & architecture overview
- Multi-tenancy isolation strategy (4-layer defense in depth)
- Storage isolation (RDS schema-based + S3 prefix-based)
- Scalability approach (20 → 50+ teams with Karpenter, RDS Proxy, multi-prefix S3)
- Security model (network policies, RBAC, IAM roles, Pod Security Standards, KMS encryption)
- **AWS Cost Estimation for eu-central-1**
  - Infrastructure: ~$911/month (mostly fixed costs)
  - Per team (50 teams): ~$18.22/month
  - Optimized (RIs + Spot + VPC endpoint): ~$591/month (~$12/team)
- Design trade-offs with rationale (shared cluster vs. dedicated, shared RDS vs. per-tenant)
- Identified bottlenecks & mitigations
- Deployment strategy & rollback procedures
- Production considerations & known limitations

### 2. [architecture/ARCHITECTURE_DIAGRAM.svg](./architecture/ARCHITECTURE_DIAGRAM.svg)
**Detailed Mermaid diagram showing:**
- AWS VPC with multi-AZ setup
- EKS cluster with namespaces per tenant
- Network policies and RBAC isolation
- Data layer (RDS, S3, ECR)
- CI/CD pipeline (GitHub Actions → CodeBuild → CodePipeline)
- Observability stack (OpenTelemetry → CloudWatch → New Relic)
- Security groups and IAM roles

## Key Design Decisions

### Multi-Tenancy: Namespace-Based
✅ **Why**: Cost-efficient, strong isolation via network policies + RBAC, scales to 50+ teams  
⚠️ **Trade-off**: Shared control plane (mitigated by cluster autoscaler + monitoring)

### Container Orchestration: EKS
✅ **Why**: Native Kubernetes support for multi-tenancy, industry standard, SRE best practices  
⚠️ **Trade-off**: Higher cost than ECS (~$73/month for control plane)

### Database: Shared RDS with Schema Isolation
✅ **Why**: Cost-efficient, simpler scaling  
⚠️ **Trade-off**: Row-level security (RLS) needed for data isolation

### Multi-AZ for RDS, Single-AZ for EKS (acceptable)
✅ **Why**: RDS Multi-AZ only costs +50%, EKS cluster autoscaler handles node failures  
✅ **Result**: High availability at reasonable cost

## AWS Region: eu-central-1

All cost estimates and configurations target **AWS eu-central-1** (Frankfurt, Germany) as specified in the assessment.

## Next Steps

1. ✅ **Architecture & Design** (Complete)
2. → **Infrastructure as Code** (Terraform in `2_infrastructure/`)
3. → **Observability** (OpenTelemetry + New Relic in `3_observability/`)
4. → **Deployment Instructions & Runbooks**

---

**Document Version**: 1.0  
**Last Updated**: May 2026  
**Status**: Ready for Infrastructure Implementation
