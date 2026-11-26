# Temporary rollout switch only. Once DPS is stable, remove this switch and
# make DPS deployment mandatory; it is not a permanent optional product feature.
variable "dps_enabled" {
  type        = bool
  default     = false
  description = "Temporary DPS rollout gate. False creates no DPS resources, ECS service or tasks."
  validation {
    condition     = !var.dps_enabled || var.dps_config != null
    error_message = "Enabling DPS requires dps_config with private subnets, image and listener material."
  }
}
variable "dps_config" {
  type = object({
    hostname        = string
    subnet_ids      = set(string)
    image           = string
    tls_secret_arn  = string
    coordinator_url = string
    alarm_topic_arn = string
    tls_kms_key_arn = optional(string)
    ca_pem          = string # Public listener trust bundle; never a private key.
  })
  default     = null
  description = "DPS rollout inputs. Supply private subnets with outbound HTTPS, a customer ECR digest and a Secrets Manager JSON secret containing TLS_CERT_PEM/TLS_KEY_PEM. Never put secret values here."
  validation {
    condition = var.dps_config == null ? true : (
      can(regex("^dps\\.[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.dps_config.hostname)) &&
      length(var.dps_config.hostname) <= 253 &&
      length(var.dps_config.subnet_ids) > 0 &&
      can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$", var.dps_config.image)) &&
      can(regex("^https://[a-zA-Z0-9.-]+(:[0-9]+)?$", var.dps_config.coordinator_url))
    )
    error_message = "DPS requires a dps.<domain> hostname, private subnets, a digest-pinned ECR image and an HTTPS Coordinator origin."
  }
}
locals {
  dps_count          = var.dps_enabled ? 1 : 0
  dps_prefix         = var.name_prefix
  dps_hostname       = var.dps_enabled ? var.dps_config.hostname : ""
  dps_port           = 9443
  dps_tags           = merge(local.common_tags, { owner = "starfolk", purpose = "private-data-plane-supervisor" })
  dps_image_path     = var.dps_enabled ? trimprefix(var.dps_config.image, "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/") : ""
  dps_repository_arn = var.dps_enabled ? "arn:aws:ecr:${var.region}:${local.account_id}:repository/${split("@", local.dps_image_path)[0]}" : ""
}

data "aws_subnet" "dps" {
  for_each = var.dps_enabled ? var.dps_config.subnet_ids : toset([])
  id       = each.value
  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id && !self.map_public_ip_on_launch
      error_message = "DPS subnets must belong to vpc_id and have public IP assignment disabled. Supply private subnets with NAT or equivalent outbound HTTPS."
    }
  }
}
# Follow an explicit subnet route-table association, or the VPC main table.
# Never create or change the customer's routing.
data "aws_route_tables" "dps_explicit" {
  for_each = var.dps_enabled ? var.dps_config.subnet_ids : toset([])
  vpc_id   = var.vpc_id
  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}
data "aws_route_table" "dps" {
  for_each = var.dps_enabled ? var.dps_config.subnet_ids : toset([])
  vpc_id   = var.vpc_id
  filter {
    name   = length(data.aws_route_tables.dps_explicit[each.key].ids) > 0 ? "route-table-id" : "association.main"
    values = length(data.aws_route_tables.dps_explicit[each.key].ids) > 0 ? data.aws_route_tables.dps_explicit[each.key].ids : ["true"]
  }
  lifecycle {
    postcondition {
      condition     = alltrue([for route in self.routes : !startswith(coalesce(route.gateway_id, "none"), "igw-")])
      error_message = "DPS requires private subnets without an Internet Gateway route. Use NAT or your private egress path."
    }
  }
}
resource "aws_ecs_cluster" "dps" {
  count = local.dps_count
  name  = "${local.dps_prefix}-dps"
  tags  = local.dps_tags
  lifecycle {
    precondition {
      condition     = startswith(var.dps_config.image, "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/")
      error_message = "Copy the approved DPS image into ECR in your account and region before enabling DPS."
    }
    precondition {
      condition     = startswith(var.dps_config.tls_secret_arn, "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:") && startswith(var.dps_config.alarm_topic_arn, "arn:aws:sns:${var.region}:${local.account_id}:")
      error_message = "The listener secret and alarm topic must be in your account and region."
    }
  }
}
resource "aws_cloudwatch_log_group" "dps" {
  count             = local.dps_count
  name              = "/${var.name_prefix}/data-plane-supervisor"
  retention_in_days = 365
  tags              = local.dps_tags
}
resource "aws_iam_role" "dps_task" {
  count = local.dps_count
  name  = "${local.dps_prefix}-dps-task"
  tags  = local.dps_tags
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole"
    Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
  }] })
  # Deliberately no permissions: no KMS signing, database, or secret-store access.
}
resource "aws_iam_role" "dps_exec" {
  count = local.dps_count
  name  = "${local.dps_prefix}-dps-exec"
  tags  = local.dps_tags
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole"
    Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
  }] })
}
resource "aws_iam_role_policy" "dps_exec" {
  count = local.dps_count
  name  = "dps-startup"
  role  = aws_iam_role.dps_exec[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = local.dps_repository_arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.dps[0].arn}:*" },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = var.dps_config.tls_secret_arn },
    ], var.dps_config.tls_kms_key_arn == null ? [] : [{
      Effect    = "Allow", Action = ["kms:Decrypt"], Resource = var.dps_config.tls_kms_key_arn
      Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" } }
  }]) })
}
resource "aws_security_group" "dps_nlb" {
  count       = local.dps_count
  name        = "${local.dps_prefix}-dps-nlb-sg"
  description = "Private DPS ingress from devboxes only"
  vpc_id      = var.vpc_id
  tags        = local.dps_tags
}
resource "aws_security_group" "dps_task" {
  count       = local.dps_count
  name        = "${local.dps_prefix}-dps-task-sg"
  description = "DPS task ingress through its private NLB only"
  vpc_id      = var.vpc_id
  tags        = local.dps_tags
}
resource "aws_vpc_security_group_ingress_rule" "dps_from_boxes" {
  count                        = local.dps_count
  security_group_id            = aws_security_group.dps_nlb[0].id
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
resource "aws_vpc_security_group_egress_rule" "dps_nlb_to_task" {
  count                        = local.dps_count
  security_group_id            = aws_security_group.dps_nlb[0].id
  referenced_security_group_id = aws_security_group.dps_task[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.dps_port
  to_port                      = local.dps_port
}
resource "aws_vpc_security_group_ingress_rule" "dps_task_from_nlb" {
  count                        = local.dps_count
  security_group_id            = aws_security_group.dps_task[0].id
  referenced_security_group_id = aws_security_group.dps_nlb[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.dps_port
  to_port                      = local.dps_port
}
resource "aws_vpc_security_group_egress_rule" "dps_task" {
  count             = local.dps_count
  security_group_id = aws_security_group.dps_task[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0" # Providers and Coordinator via NAT; not ingress.
}
resource "aws_lb" "dps" {
  count                            = local.dps_count
  name                             = "${local.dps_prefix}-dps"
  internal                         = true
  load_balancer_type               = "network"
  ip_address_type                  = "ipv4"
  subnets                          = [for subnet in data.aws_subnet.dps : subnet.id]
  security_groups                  = [aws_security_group.dps_nlb[0].id]
  enable_cross_zone_load_balancing = true # One task can serve all NLB zones.
  tags                             = local.dps_tags
}
resource "aws_lb_target_group" "dps" {
  count              = local.dps_count
  name               = "${local.dps_prefix}-dps"
  vpc_id             = var.vpc_id
  target_type        = "ip"
  port               = local.dps_port
  protocol           = "TCP"
  preserve_client_ip = true # Pending-auth per-IP quotas must see boxes, not NLB nodes.
  health_check {
    protocol = "TCP" # Listener starts only after TLS config and initial JWKS load.
  }
  tags = local.dps_tags
}
resource "aws_lb_listener" "dps" {
  count             = local.dps_count
  load_balancer_arn = aws_lb.dps[0].arn
  port              = 443
  protocol          = "TCP" # TLS terminates at DPS; never decrypt at the NLB.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dps[0].arn
  }
  tags = local.dps_tags
}
# A zone for just this hostname avoids shadowing the existing public stage zone.
resource "aws_route53_zone" "dps" {
  count = local.dps_count
  name  = local.dps_hostname
  vpc {
    vpc_id = var.vpc_id
  }
  tags = local.dps_tags
}
resource "aws_route53_record" "dps" {
  count   = local.dps_count
  zone_id = aws_route53_zone.dps[0].zone_id
  name    = local.dps_hostname
  type    = "A"
  alias {
    name                   = aws_lb.dps[0].dns_name
    zone_id                = aws_lb.dps[0].zone_id
    evaluate_target_health = true
  }
}
resource "aws_ecs_task_definition" "dps" {
  count                    = local.dps_count
  family                   = "${local.dps_prefix}-data-plane-supervisor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.dps_exec[0].arn
  task_role_arn            = aws_iam_role.dps_task[0].arn
  tags                     = local.dps_tags
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume {
    name = "dps-tls"
  }
  container_definitions = jsonencode([{
    name                   = "data-plane-supervisor"
    image                  = var.dps_config.image
    essential              = true
    user                   = "10001:10001"
    readonlyRootFilesystem = true
    linuxParameters        = { capabilities = { drop = ["ALL"] } }
    mountPoints            = [{ sourceVolume = "dps-tls", containerPath = "/run/dps", readOnly = false }]
    portMappings           = [{ containerPort = local.dps_port, protocol = "tcp" }]
    environment = [
      { name = "DPS_BIND", value = "0.0.0.0:${local.dps_port}" },
      { name = "DPS_COORDINATOR_URL", value = var.dps_config.coordinator_url },
      { name = "DPS_AUDIENCE", value = "https://${local.dps_hostname}" },
      { name = "DPS_ROOT_CA", value = "/etc/ssl/certs/ca-certificates.crt" },
    ]
    secrets = [
      { name = "DPS_TLS_CERT_PEM", valueFrom = "${var.dps_config.tls_secret_arn}:TLS_CERT_PEM::" },
      { name = "DPS_TLS_KEY_PEM", valueFrom = "${var.dps_config.tls_secret_arn}:TLS_KEY_PEM::" },
    ]
    logConfiguration = { logDriver = "awslogs", options = {
      "awslogs-group" = aws_cloudwatch_log_group.dps[0].name, "awslogs-region" = var.region, "awslogs-stream-prefix" = "dps"
    } }
  }])
}
resource "aws_ecs_service" "dps" {
  count                              = local.dps_count
  name                               = "data-plane-supervisor"
  cluster                            = aws_ecs_cluster.dps[0].id
  task_definition                    = aws_ecs_task_definition.dps[0].arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE"
  tags                               = local.dps_tags
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = [for subnet in data.aws_subnet.dps : subnet.id]
    security_groups  = [aws_security_group.dps_task[0].id]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.dps[0].arn
    container_name   = "data-plane-supervisor"
    container_port   = local.dps_port
  }
  depends_on = [aws_lb_listener.dps, aws_iam_role_policy.dps_exec, data.aws_route_table.dps]
  # Customer Terraform owns image upgrades; Starfolk receives no ECS update grant.
}
resource "aws_cloudwatch_metric_alarm" "dps_no_healthy_tasks" {
  count               = local.dps_count
  alarm_name          = "${local.dps_prefix}-dps-no-healthy-tasks"
  namespace           = "AWS/NetworkELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [var.dps_config.alarm_topic_arn]
  ok_actions          = [var.dps_config.alarm_topic_arn]
  dimensions          = { LoadBalancer = aws_lb.dps[0].arn_suffix, TargetGroup = aws_lb_target_group.dps[0].arn_suffix }
  tags                = local.dps_tags
}
resource "aws_cloudwatch_metric_alarm" "dps_resources" {
  for_each            = var.dps_enabled ? toset(["CPUUtilization", "MemoryUtilization"]) : toset([])
  alarm_name          = "${local.dps_prefix}-dps-${each.key}"
  namespace           = "AWS/ECS"
  metric_name         = each.key
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [var.dps_config.alarm_topic_arn]
  ok_actions          = [var.dps_config.alarm_topic_arn]
  dimensions          = { ClusterName = aws_ecs_cluster.dps[0].name, ServiceName = aws_ecs_service.dps[0].name }
  tags                = local.dps_tags
}
output "dps_endpoint" {
  value       = var.dps_enabled ? "https://${local.dps_hostname}:443" : null
  description = "Private-only endpoint; publishing it does not activate interception."
}


output "dps_connection" {
  value = var.dps_enabled ? {
    enabled       = true
    endpoint      = "https://${local.dps_hostname}"
    ca_pem        = var.dps_config.ca_pem
    task_role_arn = aws_iam_role.dps_task[0].arn
  } : null
  description = "Public DPS registration for Starfolk's hand-back. Null clears the registration; contains no private key or AWS credential."
}
