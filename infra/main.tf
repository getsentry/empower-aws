# Empower on AWS: storefront on S3 + CloudFront, one ECS Fargate task (agent, store API,
# Redis, OTel Collector) behind an ALB, and RDS PostgreSQL. Sized small on purpose:
# public subnets instead of a NAT gateway, one task, the smallest database.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
  backend "s3" {
    key          = "demo/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    # bucket is passed by ci/run.sh: empower-aws-tfstate-<account id>
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { project = "empower-aws", repo = "getsentry/empower-aws", shutdown = "2026-12-05" }
  }
}

variable "image_tag" {
  type        = string
  description = "Tag of the agent, store and seed images to run (the git SHA)."
  default     = "bootstrap"
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  name    = "empower-aws"
  account = data.aws_caller_identity.current.account_id
  azs     = slice(data.aws_availability_zones.available.names, 0, 2)

  # Public client keys (DSNs) for sentry-developer-experience. Not secrets.
  sentry_org_host  = "o4509446862274560.ingest.us.sentry.io"
  agent_dsn        = "https://473b6873169a9cca336b0c725a0a53a5@${local.sentry_org_host}/4512387700883456"
  store_dsn        = "https://8e3075bd45125d063b66b5d778aacfcf@${local.sentry_org_host}/4512387700948992"
  store_project_id = "4512387700948992"
  store_dsn_key    = "8e3075bd45125d063b66b5d778aacfcf"
  environment      = "aws-demo"
}

# ---------------------------------------------------------------------------- network
resource "aws_vpc" "main" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

# The database has no route to the internet and needs none.
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, 10 + count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# Only CloudFront can reach the load balancer.
resource "aws_security_group" "alb" {
  name   = "${local.name}-alb"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "task" {
  name   = "${local.name}-task"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 8000
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name   = "${local.name}-db"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }
}

# ---------------------------------------------------------------------------- database
resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}

# Slow queries and lock waits are logged with their SQL, which carries the trace ID
# (sqlcommenter in the store API), so the collector can join them to the trace.
resource "aws_db_parameter_group" "main" {
  name   = local.name
  family = "postgres16"
  parameter {
    name  = "log_min_duration_statement"
    value = "250"
  }
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }
}

resource "aws_db_instance" "main" {
  identifier                      = local.name
  engine                          = "postgres"
  engine_version                  = "16"
  instance_class                  = "db.t4g.micro"
  allocated_storage               = 20
  storage_type                    = "gp3"
  db_name                         = "empowerplant"
  username                        = "postgres"
  manage_master_user_password     = true
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  parameter_group_name            = aws_db_parameter_group.main.name
  enabled_cloudwatch_logs_exports = ["postgresql"]
  publicly_accessible             = false
  multi_az                        = false
  backup_retention_period         = 0
  skip_final_snapshot             = true
  deletion_protection             = false
  apply_immediately               = true
}

# ---------------------------------------------------------------------------- images and logs
resource "aws_ecr_repository" "repo" {
  for_each             = toset(["agent", "store", "seed"])
  name                 = "${local.name}/${each.key}"
  force_delete         = true
  image_tag_mutability = "MUTABLE"
}

resource "aws_ecr_lifecycle_policy" "repo" {
  for_each   = aws_ecr_repository.repo
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/${local.name}/ecs"
  retention_in_days = 14
}

# ---------------------------------------------------------------------------- IAM
# Every role here must be named empower-aws-* and carry the boundary; the deploy role
# can't create any other kind (see bootstrap/admin-setup.sh).
# By ARN: the deploy role can read this policy but not list policies.
locals { boundary_arn = "arn:aws:iam::${local.account}:policy/empower-aws-boundary" }

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${local.name}-task-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = local.boundary_arn
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "db-secret"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "task" {
  name                 = "${local.name}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = local.boundary_arn
}

resource "aws_iam_role_policy" "task" {
  name = "agent-and-collector"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Bedrock"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      },
      {
        Sid      = "CollectorReadsCloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:FilterLogEvents", "logs:GetLogEvents"]
        Resource = "*"
      },
      {
        Sid      = "EcsExec"
        Effect   = "Allow"
        Action   = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------- ECS
resource "aws_ecs_cluster" "main" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

locals {
  log_config = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.ecs.name
      awslogs-region        = "us-east-1"
      awslogs-stream-prefix = "app"
    }
  }
  db_password_secret = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::"

  collector_config = templatefile("${path.module}/collector.yaml", {
    otlp_base  = "https://${local.sentry_org_host}/api/${local.store_project_id}/integration/otlp"
    sentry_key    = local.store_dsn_key
    rds_log_group = "/aws/rds/instance/${local.name}/postgresql"
    ecs_log_group = aws_cloudwatch_log_group.ecs.name
  })
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 3072
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "agent"
      image        = "${aws_ecr_repository.repo["agent"].repository_url}:${var.image_tag}"
      essential    = true
      portMappings = [{ containerPort = 8000 }]
      environment = [
        { name = "SENTRY_DSN", value = local.agent_dsn },
        { name = "SENTRY_RELEASE", value = var.image_tag },
        { name = "SENTRY_ENVIRONMENT", value = local.environment },
        { name = "AWS_REGION", value = "us-east-1" },
        { name = "STORE_URL", value = "http://localhost:8080" },
      ]
      dependsOn        = [{ containerName = "store", condition = "START" }]
      logConfiguration = local.log_config
    },
    {
      name         = "store"
      image        = "${aws_ecr_repository.repo["store"].repository_url}:${var.image_tag}"
      essential    = true
      portMappings = [{ containerPort = 8080 }]
      environment = [
        { name = "FLASKOTLP_DSN", value = local.store_dsn },
        { name = "FLASKOTLP_RELEASE", value = var.image_tag },
        { name = "FLASKOTLP_ENVIRONMENT", value = local.environment },
        { name = "FLASKOTLP_REDISHOST", value = "localhost" },
        { name = "FLASKOTLP_REDISPORT", value = "6379" },
        # Empower's /products calls a Ruby API; flask-otlp serves the same /api itself.
        { name = "BACKEND_URL_RUBYONRAILS", value = "http://localhost:8080" },
        { name = "OTEL_COLLECTOR_URL", value = "http://localhost:4318/v1/traces" },
        { name = "DB_HOST", value = aws_db_instance.main.address },
        { name = "DB_DATABASE", value = "empowerplant" },
        { name = "DB_USERNAME", value = "postgres" },
      ]
      secrets          = [{ name = "DB_PASSWORD", valueFrom = local.db_password_secret }]
      dependsOn        = [{ containerName = "redis", condition = "START" }, { containerName = "collector", condition = "START" }]
      logConfiguration = local.log_config
    },
    {
      name             = "redis"
      image            = "public.ecr.aws/docker/library/redis:7-alpine"
      essential        = true
      logConfiguration = local.log_config
    },
    {
      name             = "collector"
      image            = "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.145.0"
      essential        = true
      command          = ["--config=env:OTEL_CONFIG"]
      environment      = [{ name = "OTEL_CONFIG", value = local.collector_config }]
      logConfiguration = local.log_config
    },
  ])
}

# One-off task that loads Empower's catalogue into RDS (run by ci/run.sh).
resource "aws_ecs_task_definition" "seed" {
  family                   = "${local.name}-seed"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn
  container_definitions = jsonencode([{
    name      = "seed"
    image     = "${aws_ecr_repository.repo["seed"].repository_url}:${var.image_tag}"
    essential = true
    environment = [
      { name = "PGHOST", value = aws_db_instance.main.address },
      { name = "PGDATABASE", value = "empowerplant" },
      { name = "PGUSER", value = "postgres" },
      { name = "PGSSLMODE", value = "require" },
    ]
    secrets          = [{ name = "PGPASSWORD", valueFrom = local.db_password_secret }]
    logConfiguration = local.log_config
  }])
}

resource "aws_ecs_service" "app" {
  name                               = local.name
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  enable_execute_command             = true
  health_check_grace_period_seconds  = 120
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.agent.arn
    container_name   = "agent"
    container_port   = 8000
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.store.arn
    container_name   = "store"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener_rule.agent]
}

# ---------------------------------------------------------------------------- load balancer
resource "aws_lb" "main" {
  name               = local.name
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = 300
}

resource "aws_lb_target_group" "store" {
  name        = "${local.name}-store"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check {
    path    = "/success"
    matcher = "200-399"
  }
}

resource "aws_lb_target_group" "agent" {
  name        = "${local.name}-agent"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id
  health_check {
    path    = "/agent/health"
    matcher = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.store.arn
  }
}

resource "aws_lb_listener_rule" "agent" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10
  condition {
    path_pattern { values = ["/agent", "/agent/*"] }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.agent.arn
  }
}

# ---------------------------------------------------------------------------- storefront and CDN
resource "aws_s3_bucket" "storefront" {
  bucket        = "${local.name}-storefront-${local.account}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "storefront" {
  bucket                  = aws_s3_bucket.storefront.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "storefront" {
  name                              = "${local.name}-storefront"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "storefront" {
  bucket = aws_s3_bucket.storefront.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.storefront.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.main.arn } }
    }]
  })
}

# React Router paths (/products, /checkout, ...) are served the app's index.html.
resource "aws_cloudfront_function" "spa" {
  name    = "${local.name}-spa"
  runtime = "cloudfront-js-2.0"
  code    = <<-EOF
    function handler(event) {
      var request = event.request;
      if (request.uri.indexOf('.') === -1) request.uri = '/index.html';
      return request;
    }
  EOF
}

# The storefront calls the store API at /store/...; the API itself serves /....
resource "aws_cloudfront_function" "strip_store" {
  name    = "${local.name}-strip-store"
  runtime = "cloudfront-js-2.0"
  code    = <<-EOF
    function handler(event) {
      var request = event.request;
      request.uri = request.uri.replace(/^\/store/, '') || '/';
      return request;
    }
  EOF
}

data "aws_cloudfront_cache_policy" "disabled" { name = "Managed-CachingDisabled" }
data "aws_cloudfront_cache_policy" "optimized" { name = "Managed-CachingOptimized" }
data "aws_cloudfront_origin_request_policy" "all_viewer" { name = "Managed-AllViewerExceptHostHeader" }

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "Empower on AWS (re:Invent demo)"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "storefront"
    domain_name              = aws_s3_bucket.storefront.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.storefront.id
  }

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.main.dns_name
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }
  }

  default_cache_behavior {
    target_origin_id       = "storefront"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa.arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/store/*"
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.strip_store.arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/agent/*"
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  # The custom domain is attached once its certificate is issued, which needs the
  # validation record in sentry.dev's DNS (Vercel). Until then the default address serves.
  aliases = local.domain_ready ? [var.custom_domain] : []
  viewer_certificate {
    cloudfront_default_certificate = local.domain_ready ? null : true
    acm_certificate_arn            = local.domain_ready ? aws_acm_certificate.custom.arn : null
    ssl_support_method             = local.domain_ready ? "sni-only" : null
    minimum_protocol_version       = local.domain_ready ? "TLSv1.2_2021" : null
  }
}

# ---------------------------------------------------------------------------- custom domain
variable "custom_domain" {
  type    = string
  default = "reinvent.sentry.dev"
}

resource "aws_acm_certificate" "custom" {
  domain_name       = var.custom_domain
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

locals { domain_ready = aws_acm_certificate.custom.status == "ISSUED" }

output "custom_domain_status" { value = aws_acm_certificate.custom.status }
output "custom_domain_dns" {
  description = "DNS records to add in sentry.dev's zone."
  value = concat(
    [for o in aws_acm_certificate.custom.domain_validation_options : "${o.resource_record_name} ${o.resource_record_type} ${o.resource_record_value}"],
    ["${var.custom_domain}. CNAME ${aws_cloudfront_distribution.main.domain_name}"],
  )
}

# ---------------------------------------------------------------------------- outputs
output "url" { value = "https://${aws_cloudfront_distribution.main.domain_name}" }
output "distribution_id" { value = aws_cloudfront_distribution.main.id }
output "storefront_bucket" { value = aws_s3_bucket.storefront.bucket }
output "cluster" { value = aws_ecs_cluster.main.name }
output "service" { value = aws_ecs_service.app.name }
output "seed_task_definition" { value = aws_ecs_task_definition.seed.arn }
output "public_subnets" { value = join(",", aws_subnet.public[*].id) }
output "task_security_group" { value = aws_security_group.task.id }
output "ecr" { value = { for k, r in aws_ecr_repository.repo : k => r.repository_url } }
