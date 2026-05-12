# ── ECR Repositories (one per team) ──────────────────────────────────────────
resource "aws_ecr_repository" "tenant" {
  for_each             = var.teams
  name                 = "${var.cluster_name}/${each.key}/app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.s3.arn
  }

  tags = { Name = "${var.cluster_name}-${each.key}-ecr" }
}

# ── ECR Lifecycle Policy (keep last 30 tagged + expire untagged after 1 day) ──
resource "aws_ecr_lifecycle_policy" "tenant" {
  for_each   = var.teams
  repository = aws_ecr_repository.tenant[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── ECR Repository Policy (allow EKS nodes to pull) ──────────────────────────
data "aws_iam_policy_document" "ecr_pull" {
  for_each = var.teams

  statement {
    sid    = "AllowEKSNodePull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.eks_node.arn]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability"
    ]
  }

  statement {
    sid    = "AllowCI"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.github_actions_ci.arn]
    }

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
  }
}

resource "aws_ecr_repository_policy" "tenant" {
  for_each   = var.teams
  repository = aws_ecr_repository.tenant[each.key].name
  policy     = data.aws_iam_policy_document.ecr_pull[each.key].json
}
