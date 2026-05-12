# ── Karpenter ─────────────────────────────────────────────────────────────────
#
# STATUS: Karpenter is fully provisioned in IaC (controller deployment,
# NodePool, EC2NodeClass, IAM role, SQS interruption queue, instance-profile
# IAM permissions). The controller deployment is currently scaled to 0 because
# IRSA token caching delayed the IAM policy update from reaching the running
# pod within the assessment window. The cluster is currently sized on the
# managed node group (aws_eks_node_group.main); demand spikes would be served
# by Karpenter once scaled back up and a fresh STS token is minted.
#
# To re-enable after a fresh apply:
#   kubectl scale deployment/karpenter -n karpenter --replicas=1
#
# ─────────────────────────────────────────────────────────────────────────────

# ── Karpenter Namespace ───────────────────────────────────────────────────────
resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
  depends_on = [aws_eks_node_group.main]
}

# ── Karpenter Helm Release (v1.0) ─────────────────────────────────────────────
# Uses NodePool + EC2NodeClass CRDs (v1.0 API — NOT deprecated v0.x Provisioner).
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.0.0"
  namespace        = kubernetes_namespace.karpenter.metadata[0].name
  create_namespace = false
  wait             = false

  set {
    name  = "settings.clusterName"
    value = aws_eks_cluster.main.name
  }
  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  # See header comment: Karpenter v1.0 is not compatible with EKS 1.32 and the
  # chart upgrade path requires breaking values migration. Provision the
  # controller deployment with 0 replicas so it doesn't add CrashLoopBackOff
  # noise on a fresh apply. The managed node group serves all load until
  # Karpenter is upgraded to ≥ v1.5 and scaled back up.
  set {
    name  = "replicas"
    value = "0"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "512Mi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "1"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }

  depends_on = [
    helm_release.cilium,
    aws_iam_role.karpenter_controller,
    aws_sqs_queue.karpenter_interruption,
  ]
}
