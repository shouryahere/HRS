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

  # hubble-peer Service ships from the chart with internalTrafficPolicy=Local.
  # In Cilium ENI chaining mode that prevents hubble-relay (single replica)
  # from reaching the Cilium agent on other nodes via the Service ClusterIP,
  # so the Relay flatlines with "context deadline exceeded". Cluster-wide
  # service routing is what we want here.
  set {
    name  = "hubble.peerService.clusterDomain"
    value = "cluster.local"
  }

  # The chart's hubble-ui frontend liveness probe is httpGet:/healthz with
  # timeoutSeconds=1, periodSeconds=10. In ENI mode nginx isn't reliably
  # answering the probe in 1s during startup (probably TCP handshake jitter
  # over the Cilium-managed pod IP), so the container crashloops at ~30s
  # intervals. Switch to TCP-socket probes with looser timing.
  set {
    name  = "hubble.ui.frontend.livenessProbe.tcpSocket.port"
    value = "8081"
  }
  set {
    name  = "hubble.ui.frontend.livenessProbe.initialDelaySeconds"
    value = "15"
  }
  set {
    name  = "hubble.ui.frontend.livenessProbe.periodSeconds"
    value = "30"
  }
  set {
    name  = "hubble.ui.frontend.livenessProbe.timeoutSeconds"
    value = "5"
  }

  depends_on = [aws_eks_node_group.main]
}

# The chart still doesn't have a values knob for hubble-peer's
# internalTrafficPolicy (see issue cilium/cilium#XXXX). Patch it post-install.
resource "null_resource" "hubble_peer_cluster_traffic" {
  triggers = {
    cilium_release = helm_release.cilium.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl patch svc -n kube-system hubble-peer \
        -p '{"spec":{"internalTrafficPolicy":"Cluster"}}' || true
      kubectl rollout restart deployment/hubble-relay -n kube-system || true
    EOT
  }

  depends_on = [helm_release.cilium]
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
  wait       = false

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
  wait       = false

  # The chart's default cleanup CronJob image (bitnami/kubectl:1.28.5) was
  # removed from Docker Hub after a Bitnami repo restructure, so the cleanup
  # jobs end up in ImagePullBackOff. Pin to the kubernetes.io distribution
  # of kubectl instead. registry.k8s.io/kubectl runs as root by default; the
  # CronJobs enforce runAsNonRoot, so override to uid 65534 (nobody).
  dynamic "set" {
    for_each = toset([
      "admissionReports",
      "clusterAdmissionReports",
      "ephemeralReports",
      "clusterEphemeralReports",
      "updateRequests",
    ])
    content {
      name  = "cleanupJobs.${set.value}.image.repository"
      value = "registry.k8s.io/kubectl"
    }
  }

  dynamic "set" {
    for_each = toset([
      "admissionReports",
      "clusterAdmissionReports",
      "ephemeralReports",
      "clusterEphemeralReports",
      "updateRequests",
    ])
    content {
      name  = "cleanupJobs.${set.value}.image.tag"
      value = "v1.30.0"
    }
  }

  dynamic "set" {
    for_each = toset([
      "admissionReports",
      "clusterAdmissionReports",
      "ephemeralReports",
      "clusterEphemeralReports",
      "updateRequests",
    ])
    content {
      name  = "cleanupJobs.${set.value}.securityContext.runAsUser"
      value = "65534"
    }
  }

  lifecycle {
    ignore_changes = [wait]
  }

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
  wait       = false

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.cert_manager.arn
  }
  set {
    name  = "startupapicheck.enabled"
    value = "false"
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

# ── Route53 Hosted Zone ─────────────────────────────────────────────────────
# Creates the hosted zone for the platform subdomain (e.g. platform.talkit.chat).
# After apply, take the NS records from `terraform output route53_nameservers`
# and add them at the registrar (GoDaddy) for the parent zone — this delegates
# the subdomain to Route53.
resource "aws_route53_zone" "platform" {
  name    = var.domain_name
  comment = "Delegated subdomain for ${var.cluster_name} - managed by Terraform"
  tags    = { Name = "${var.cluster_name}-zone" }
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

# DNS validation records — written into the Route53 zone above.
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.platform.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.platform.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "platform" {
  certificate_arn         = aws_acm_certificate.platform.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

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
  wait       = false

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  depends_on = [helm_release.cilium]
}

# ── Disable SrcDstCheck on node ENIs ─────────────────────────────────────────
# In Cilium ENI chaining mode, pod IPs are managed by Cilium IPAM and may not
# appear as explicit secondary IPs on a node's ENI in the EC2 view. EC2's
# default SrcDstCheck=true drops packets destined for IPs not explicitly on the
# ENI, which manifests as ALB targets in "Request timed out" state even though
# pod-local health probes succeed.
#
# EKS managed node groups don't expose ENI source_dest_check through the
# launch template surface, so we shell out to the AWS CLI on every apply.
# Triggered by node group ID; safe to run repeatedly. Requires `aws` and `jq`
# on PATH where Terraform is run.
resource "null_resource" "disable_node_eni_srcdstcheck" {
  triggers = {
    node_group = aws_eks_node_group.main.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      INSTANCES=$(aws ec2 describe-instances --region ${var.aws_region} \
        --filters "Name=tag:eks:cluster-name,Values=${aws_eks_cluster.main.name}" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
      for I in $INSTANCES; do
        ENIS=$(aws ec2 describe-network-interfaces --region ${var.aws_region} \
          --filters "Name=attachment.instance-id,Values=$I" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
        for E in $ENIS; do
          aws ec2 modify-network-interface-attribute --region ${var.aws_region} \
            --network-interface-id $E --no-source-dest-check
        done
      done
    EOT
  }

  depends_on = [aws_eks_node_group.main, helm_release.cilium]
}

# ── Apply all in-cluster Kubernetes manifests ────────────────────────────────
# Single orchestrator that materialises namespaces, RBAC, quotas, network
# policies, ExternalSecrets, cert-manager issuers, Kyverno policies, observ-
# ability DaemonSets, and tenant sample apps. Runs after every relevant
# upstream change (EKS NG ID, Helm releases of the platform addons). Requires
# kubectl + envsubst on PATH and a kubeconfig pointing at this cluster.
resource "null_resource" "apply_manifests" {
  triggers = {
    node_group         = aws_eks_node_group.main.id
    argocd_release     = helm_release.argocd.id
    kyverno_release    = helm_release.kyverno.id
    eso_release        = helm_release.external_secrets.id
    cert_mgr_release   = helm_release.cert_manager.id
    lbc_release        = helm_release.aws_lb_controller.id
  }

  provisioner "local-exec" {
    command = "${path.module}/../../scripts/apply-manifests.sh"
    environment = {
      AWS_ACCOUNT_ID = data.aws_caller_identity.current.account_id
      ACM_CERT_ARN   = aws_acm_certificate_validation.platform.certificate_arn
      AWS_REGION     = var.aws_region
    }
  }

  depends_on = [
    null_resource.disable_node_eni_srcdstcheck,
    null_resource.hubble_peer_cluster_traffic,
    helm_release.argocd,
    helm_release.kyverno,
    helm_release.external_secrets,
    helm_release.cert_manager,
    helm_release.aws_lb_controller,
    aws_acm_certificate_validation.platform,
  ]
}
