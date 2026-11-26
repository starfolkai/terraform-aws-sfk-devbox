mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_route_tables" { defaults = { ids = ["rtb-0123456789abcdef0"] } }
  mock_data "aws_route_table" { defaults = { routes = [] } }
  mock_data "aws_subnet" { defaults = { vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false } }
  mock_resource "aws_security_group" { defaults = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/sfk-test" } }
  mock_resource "aws_ecs_cluster" { defaults = { arn = "arn:aws:ecs:us-east-2:123456789012:cluster/sfk-devbox-dps" } }
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-2:123456789012:loadbalancer/net/sfk-test/0000000000000000"
      arn_suffix = "net/sfk-test/0000000000000000"
      zone_id    = "Z0123456789ABCD"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-2:123456789012:targetgroup/sfk-test/0000000000000000"
      arn_suffix = "targetgroup/sfk-test/0000000000000000"
    }
  }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-2:123456789012:log-group:/sfk-test/dps" } }
}
mock_provider "random" {}
variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}
run "default_creates_no_dps" {
  command = apply
  assert {
    condition = (
      length(aws_ecs_cluster.dps) == 0 &&
      length(aws_ecs_service.dps) == 0 &&
      length(aws_ecs_task_definition.dps) == 0 &&
      length(aws_lb.dps) == 0 &&
      length(aws_security_group.dps_task) == 0 &&
      length(aws_iam_role.dps_exec) == 0 &&
      length(aws_route53_zone.dps) == 0 &&
      length(aws_cloudwatch_log_group.dps) == 0 &&
      output.dps_endpoint == null
    )
    error_message = "Default rollout gate must create no DPS resources or endpoint."
  }
}
run "enabled_private_service" {
  command = apply
  variables {
    dps_enabled = true
    dps_config = {
      hostname        = "dps.customer.org.starfolk.io"
      subnet_ids      = ["subnet-0123456789abcdef0"]
      image           = "123456789012.dkr.ecr.us-east-2.amazonaws.com/starfolk/dps@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      tls_secret_arn  = "arn:aws:secretsmanager:us-east-2:123456789012:secret:dps-tls-123456"
      coordinator_url = "https://api.prod.starfolk.io"
      alarm_topic_arn = "arn:aws:sns:us-east-2:123456789012:operations"
    }
  }
  assert {
    condition = (
      aws_ecs_service.dps[0].desired_count == 1 &&
      !aws_ecs_service.dps[0].network_configuration[0].assign_public_ip &&
      aws_ecs_service.dps[0].deployment_minimum_healthy_percent == 100 &&
      aws_ecs_service.dps[0].deployment_maximum_percent == 200 &&
      aws_lb.dps[0].internal &&
      aws_lb_listener.dps[0].protocol == "TCP" &&
      aws_lb_target_group.dps[0].preserve_client_ip
    )
    error_message = "DPS must be private, preserve source IP and start replacements before retirement."
  }
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.dps_from_boxes[0].referenced_security_group_id == aws_security_group.this.id &&
      aws_vpc_security_group_ingress_rule.dps_task_from_nlb[0].referenced_security_group_id == aws_security_group.dps_nlb[0].id &&
      aws_vpc_security_group_ingress_rule.dps_from_boxes[0].cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.dps_task_from_nlb[0].cidr_ipv4 == null &&
      one(aws_route53_zone.dps[0].vpc).vpc_id == var.vpc_id &&
      output.dps_endpoint == "https://dps.customer.org.starfolk.io:443"
    )
    error_message = "Only the devbox SG reaches the private NLB and only its SG reaches tasks."
  }
  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.dps[0].container_definitions)[0].image == var.dps_config.image &&
      jsondecode(aws_ecs_task_definition.dps[0].container_definitions)[0].readonlyRootFilesystem &&
      jsondecode(aws_ecs_task_definition.dps[0].container_definitions)[0].user == "10001:10001" &&
      aws_cloudwatch_log_group.dps[0].retention_in_days == 365 &&
      local.dps_repository_arn == "arn:aws:ecr:us-east-2:123456789012:repository/starfolk/dps"
    )
    error_message = "Use the supplied immutable image with non-root/read-only execution and scoped ECR access."
  }
}
run "disabled_even_with_configuration" {
  command = apply
  variables {
    dps_enabled = false
    dps_config = {
      hostname        = "dps.customer.org.starfolk.io"
      subnet_ids      = ["subnet-0123456789abcdef0"]
      image           = "123456789012.dkr.ecr.us-east-2.amazonaws.com/starfolk/dps@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      tls_secret_arn  = "arn:aws:secretsmanager:us-east-2:123456789012:secret:dps-tls-123456"
      coordinator_url = "https://api.prod.starfolk.io"
      alarm_topic_arn = "arn:aws:sns:us-east-2:123456789012:operations"
    }
  }
  assert {
    condition     = length(aws_ecs_service.dps) == 0 && length(aws_ecs_task_definition.dps) == 0 && length(aws_ecs_cluster.dps) == 0 && output.dps_endpoint == null
    error_message = "Supplying configuration must not bypass the explicit rollout gate."
  }
}
run "enabled_requires_configuration" {
  command = plan
  variables { dps_enabled = true }
  expect_failures = [var.dps_enabled]
}

run "reject_public_subnet" {
  command = plan
  variables {
    dps_enabled = true
    dps_config = {
      hostname        = "dps.customer.org.starfolk.io"
      subnet_ids      = ["subnet-0123456789abcdef0"]
      image           = "123456789012.dkr.ecr.us-east-2.amazonaws.com/starfolk/dps@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      tls_secret_arn  = "arn:aws:secretsmanager:us-east-2:123456789012:secret:dps-tls-123456"
      coordinator_url = "https://api.prod.starfolk.io"
      alarm_topic_arn = "arn:aws:sns:us-east-2:123456789012:operations"
    }
  }
  override_data {
    target = data.aws_subnet.dps["subnet-0123456789abcdef0"]
    values = { vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = true }
  }
  expect_failures = [data.aws_subnet.dps["subnet-0123456789abcdef0"]]
}

run "reject_wrong_vpc" {
  command = plan
  variables {
    dps_enabled = true
    dps_config = {
      hostname        = "dps.customer.org.starfolk.io"
      subnet_ids      = ["subnet-0123456789abcdef0"]
      image           = "123456789012.dkr.ecr.us-east-2.amazonaws.com/starfolk/dps@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      tls_secret_arn  = "arn:aws:secretsmanager:us-east-2:123456789012:secret:dps-tls-123456"
      coordinator_url = "https://api.prod.starfolk.io"
      alarm_topic_arn = "arn:aws:sns:us-east-2:123456789012:operations"
    }
  }
  override_data {
    target = data.aws_subnet.dps["subnet-0123456789abcdef0"]
    values = { vpc_id = "vpc-fffffffffffffffff", map_public_ip_on_launch = false }
  }
  expect_failures = [data.aws_subnet.dps["subnet-0123456789abcdef0"]]
}

run "reject_internet_gateway_route" {
  command = plan
  variables {
    dps_enabled = true
    dps_config = {
      hostname        = "dps.customer.org.starfolk.io"
      subnet_ids      = ["subnet-0123456789abcdef0"]
      image           = "123456789012.dkr.ecr.us-east-2.amazonaws.com/starfolk/dps@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      tls_secret_arn  = "arn:aws:secretsmanager:us-east-2:123456789012:secret:dps-tls-123456"
      coordinator_url = "https://api.prod.starfolk.io"
      alarm_topic_arn = "arn:aws:sns:us-east-2:123456789012:operations"
    }
  }
  override_data {
    target = data.aws_route_table.dps["subnet-0123456789abcdef0"]
    values = { routes = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-0123456789abcdef0" }] }
  }
  expect_failures = [data.aws_route_table.dps["subnet-0123456789abcdef0"]]
}
