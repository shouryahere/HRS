# ── KMS key for etcd secrets encryption ──────────────────────────────────────
resource "aws_kms_key" "eks_secrets" {
  description             = "${var.cluster_name} EKS etcd secrets encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags                    = { Name = "${var.cluster_name}-eks-secrets-key" }
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids      = [aws_security_group.eks_nodes.id]
    endpoint_private_access = true
    endpoint_public_access  = var.eks_endpoint_public_access
    public_access_cidrs     = var.eks_endpoint_public_access ? var.eks_public_access_cidrs : null
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler"
  ]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks_audit,
  ]

  tags = { Name = var.cluster_name }
}

resource "aws_cloudwatch_log_group" "eks_audit" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 90
}

# ── OIDC provider (used for IRSA) ─────────────────────────────────────────────
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
  oidc_arn    = aws_iam_openid_connect_provider.eks.arn
}

# ── Managed Node Group ────────────────────────────────────────────────────────
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "eks.amazonaws.com/nodegroup" = "${var.cluster_name}-nodes"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy,
  ]

  tags = { Name = "${var.cluster_name}-nodes" }
}

# ── EKS Managed Add-ons ───────────────────────────────────────────────────────
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.main]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.vpc_cni.arn
}

# ── Cilium — installed via Helm (chaining mode on top of VPC CNI) ─────────────
# Cilium is also available as an EKS managed add-on from the AWS Marketplace,
# but Helm gives explicit version control and configuration clarity for this assessment.
resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = "1.15.6"
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "eni.enabled"
    value = "true"
  }
  set {
    name  = "ipam.mode"
    value = "eni"
  }
  set {
    name  = "egressMasqueradeInterfaces"
    value = "eth0"
  }
  set {
    name  = "tunnel"
    value = "disabled"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }

  depends_on = [aws_eks_node_group.main]
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.3.4"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "configs.params.server\\.insecure"
    value = "false"
  }

  depends_on = [helm_release.cilium]
}

# ── Kyverno ───────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "kyverno" {
  name       = "kyverno"
  repository = "https://kyverno.github.io/kyverno"
  chart      = "kyverno"
  version    = "3.2.6"
  namespace  = kubernetes_namespace.kyverno.metadata[0].name

  depends_on = [helm_release.cilium]
}

# ── cert-manager ──────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "1.15.1"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cert_manager.arn
  }

  depends_on = [helm_release.cilium]
}

# ── AWS Load Balancer Controller ─────────────────────────────────────────────
# Translates Kubernetes Ingress resources into AWS ALBs.
# Installed in kube-system so it's centrally managed.
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.main.name
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.aws_lb_controller.arn
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = aws_vpc.main.id
  }

  depends_on = [helm_release.cilium]
}

# ── ACM Certificate for ALB ─────────────────────────────────────────────────
# Issues a wildcard TLS certificate validated via DNS in Route53.
# Attached by the AWS Load Balancer Controller to the ALB listener.
# Distinct from cert-manager's Let's Encrypt cert — that one is for in-cluster TLS.
resource "aws_acm_certificate" "platform" {
  domain_name               = "*.${var.domain_name}"
  subject_alternative_names = [var.domain_name]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.cluster_name}-platform-cert" }
}

# Note: DNS validation records must be created in Route53. If the hosted zone
# is in this account, add `aws_route53_record` + `aws_acm_certificate_validation`.
# Left out here because hosted-zone ownership is environment-specific.

# ── External Secrets Operator ─────────────────────────────────────────────────
resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "0.10.3"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  depends_on = [helm_release.cilium]
}
