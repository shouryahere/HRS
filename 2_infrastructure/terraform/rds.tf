# ── RDS Subnet Group ──────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-rds-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.cluster_name}-rds-subnet-group" }
}

# ── RDS Parameter Group (enforce SSL + row_security) ─────────────────────────
resource "aws_db_parameter_group" "postgres" {
  name   = "${var.cluster_name}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "row_security"
    value = "on"
  }

  tags = { Name = "${var.cluster_name}-pg16-params" }
}

# ── RDS PostgreSQL Instance ───────────────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier        = "${var.cluster_name}-postgres"
  engine            = "postgres"
  engine_version    = "16.3"
  instance_class    = var.rds_instance_class
  allocated_storage = 100
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.rds_database_name
  username = var.rds_master_username
  password = var.rds_master_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name

  # Multi-AZ for 99.9% SLO
  multi_az = true

  # Automated backups with 7-day retention
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Minor version auto-upgrade; major version upgrade is manual
  auto_minor_version_upgrade = true

  deletion_protection = true
  skip_final_snapshot = false
  final_snapshot_identifier = "${var.cluster_name}-postgres-final-snapshot"

  # Enhanced monitoring
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  # Performance Insights
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = { Name = "${var.cluster_name}-postgres" }
}

# RDS enhanced monitoring role
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.cluster_name}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── RDS Proxy (connection pooling — absorbs 1000+ client connections) ─────────
resource "aws_iam_role" "rds_proxy" {
  name = "${var.cluster_name}-rds-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "rds_proxy_secrets" {
  name = "${var.cluster_name}-rds-proxy-secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = aws_secretsmanager_secret.rds_master.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_proxy_secrets" {
  role       = aws_iam_role.rds_proxy.name
  policy_arn = aws_iam_policy.rds_proxy_secrets.arn
}

# Master password stored in Secrets Manager so RDS Proxy can fetch it
resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "hrs/${var.cluster_name}/rds-master"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = var.rds_master_username
    password = var.rds_master_password
  })
}

resource "aws_db_proxy" "main" {
  name                   = "${var.cluster_name}-rds-proxy"
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_security_group_ids = [aws_security_group.rds.id]
  vpc_subnet_ids         = aws_subnet.private[*].id

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.rds_master.arn
  }

  # Proxy needs the secret VALUE to exist, not just the secret resource.
  depends_on = [
    aws_secretsmanager_secret_version.rds_master,
    aws_iam_role_policy_attachment.rds_proxy_secrets,
  ]

  tags = { Name = "${var.cluster_name}-rds-proxy" }
}

resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name

  connection_pool_config {
    # Allow up to 100% of max_connections to be used by the proxy pool
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    # 2-second borrow timeout prevents pile-up during spikes
    connection_borrow_timeout    = 2
  }
}

resource "aws_db_proxy_target" "main" {
  db_instance_identifier = aws_db_instance.main.id
  db_proxy_name          = aws_db_proxy.main.name
  target_group_name      = aws_db_proxy_default_target_group.main.name
}

# ── CloudWatch alarms for RDS ─────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.cluster_name}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_description = "RDS CPU > 80% for 10 minutes"
  treat_missing_data = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.cluster_name}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 900

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_description  = "RDS connections approaching limit"
  treat_missing_data = "notBreaching"
}
