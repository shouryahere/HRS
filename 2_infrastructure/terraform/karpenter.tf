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
