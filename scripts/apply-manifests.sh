#!/usr/bin/env bash
# apply-manifests.sh — Applies all Kubernetes manifests in dependency order.
#
# Prerequisites:
#   - terraform apply completed successfully (EKS, IAM roles, ECR, Secrets Manager all in place)
#   - kubeconfig pointing at the cluster
#   - .secrets.local sourced (for ACM_CERT_ARN and AWS_ACCOUNT_ID if not already exported)
#   - Tenant container images pushed to their team-NN/app ECR repos
#
# Usage: ./scripts/apply-manifests.sh

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)
TF_DIR="${REPO_ROOT}/2_infrastructure/terraform"
K8S_DIR="${REPO_ROOT}/2_infrastructure/k8s"
OBS_DIR="${REPO_ROOT}/3_observability"
REGION="${AWS_REGION:-eu-central-1}"

# Pull substitution values from terraform outputs.
echo "→ Reading terraform outputs"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(terraform -chdir="${TF_DIR}" output -raw aws_account_id 2>/dev/null)}"
ACM_CERT_ARN="${ACM_CERT_ARN:-$(terraform -chdir="${TF_DIR}" output -raw acm_certificate_arn 2>/dev/null)}"
FLUENT_BIT_ROLE_ARN="$(terraform -chdir="${TF_DIR}" output -raw fluent_bit_role_arn 2>/dev/null)"

export AWS_ACCOUNT_ID ACM_CERT_ARN

# ── 1. Namespaces (with PSS labels) ─────────────────────────────────────────
echo "→ [1/8] Namespaces"
kubectl apply -f "${K8S_DIR}/namespaces/"

# ── 2. RBAC (per-team Role/RoleBinding bound to OIDC group claims) ──────────
echo "→ [2/8] RBAC"
kubectl apply -f "${K8S_DIR}/rbac/"

# ── 3. Resource quotas + limit ranges ───────────────────────────────────────
echo "→ [3/8] ResourceQuotas / LimitRanges"
kubectl apply -f "${K8S_DIR}/quotas/"

# ── 4. NetworkPolicies (tenant) + CiliumNetworkPolicies (platform) ──────────
echo "→ [4/8] Network policies"
kubectl apply -f "${K8S_DIR}/network-policies/tenant-network-policies.yaml"
kubectl apply -f "${K8S_DIR}/network-policies/platform-cilium-network-policies.yaml"

# ── 5. ExternalSecrets store + per-tenant ExternalSecrets ──────────────────
echo "→ [5/8] External Secrets"
kubectl apply -f "${K8S_DIR}/external-secrets/"

# ── 6. cert-manager Issuer + Certificate ────────────────────────────────────
echo "→ [6/8] cert-manager"
kubectl apply -f "${K8S_DIR}/cert-manager/"

# ── 7. Kyverno policies (image registry restriction, PSS, etc.) ─────────────
echo "→ [7/8] Kyverno policies"
kubectl apply -f "${K8S_DIR}/kyverno/"

# ── 8. Observability stack (Fluent Bit + OTel Collector) ────────────────────
echo "→ [8/8] Observability stack"
# Patch fluent-bit IRSA annotation in place using envsubst.
FB_ROLE_ARN="${FLUENT_BIT_ROLE_ARN}" envsubst < "${OBS_DIR}/fluent-bit/fluent-bit.yaml" | \
  sed "s|eks.amazonaws.com/role-arn: \"\"|eks.amazonaws.com/role-arn: \"${FLUENT_BIT_ROLE_ARN}\"|" | \
  kubectl apply -f -
kubectl apply -f "${OBS_DIR}/otel/otel-collector.yaml"

# ── 9. Tenant workloads ────────────────────────────────────────────────────
echo "→ [9/9] Tenant sample apps"
for TEAM_ID in team-01 team-02 team-03; do
  export TEAM_ID
  envsubst < "${OBS_DIR}/sample-app/deployment.yaml" | kubectl apply -f -
done

echo
echo "✓ All manifests applied."
echo
echo "Verify with:"
echo "  for T in team-01 team-02 team-03; do"
echo "    HOST=\$(kubectl get ing -n \$T sample-app -o jsonpath='{.spec.rules[0].host}')"
echo "    ADDR=\$(kubectl get ing -n \$T sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "    echo \"\$T: \$(curl -s -o /dev/null -w '%{http_code}' -k -H \"Host: \$HOST\" https://\$ADDR/)\""
echo "  done"
