# ── S3 Asset Bucket (multi-prefix sharding for 50K PUT/s) ────────────────────
# Minimum 15 shards: ceil(50,000 PUT/s ÷ 3,500/s per prefix) = 15.
# Consistent hashing on team-ID distributes writes across shard prefixes.
resource "aws_s3_bucket" "assets" {
  bucket = "${var.cluster_name}-assets"

  tags = { Name = "${var.cluster_name}-assets" }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# KMS key for S3 (separate from EKS etcd key)
resource "aws_kms_key" "s3" {
  description             = "${var.cluster_name} S3 assets encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  tags                    = { Name = "${var.cluster_name}-s3-key" }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.cluster_name}-s3"
  target_key_id = aws_kms_key.s3.key_id
}

# ── Terraform State Bucket (outputs for reference; created by bootstrap.sh) ───
# The state bucket is NOT managed by Terraform to avoid a chicken-and-egg problem.
# It is created by scripts/bootstrap.sh before `terraform init`.

# ── S3 Access Logging Bucket ──────────────────────────────────────────────────
resource "aws_s3_bucket" "access_logs" {
  bucket = "${var.cluster_name}-access-logs"

  tags = { Name = "${var.cluster_name}-access-logs" }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_logging" "assets" {
  bucket        = aws_s3_bucket.assets.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "assets-access-logs/"
}
