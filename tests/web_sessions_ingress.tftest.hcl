mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
  ssh_ingress_cidrs  = ["203.0.113.0/24"]
}

run "both_optional_ports_are_closed_by_default" {
  command = plan

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.ssh_webpty) == 1 &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.ssh_webpty :
        rule.from_port == 22 && rule.to_port == 22 && rule.cidr_ipv4 == "203.0.113.0/24"
      ]) &&
      length(aws_vpc_security_group_ingress_rule.coordinator) == 0
    )
    error_message = "By default, the security group must open only SSH to ssh_ingress_cidrs."
  }
}

run "web_sessions_open_443_to_ssh_cidrs_only" {
  command = plan

  variables {
    enable_web_sessions = true
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.ssh_webpty) == 2 &&
      toset([
        for rule in aws_vpc_security_group_ingress_rule.ssh_webpty : rule.from_port
      ]) == toset([22, 443]) &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.ssh_webpty :
        rule.cidr_ipv4 == "203.0.113.0/24"
      ]) &&
      length(aws_vpc_security_group_ingress_rule.coordinator) == 0
    )
    error_message = "enable_web_sessions must add TCP 443 using ssh_ingress_cidrs without opening TCP 7681."
  }
}

run "coordinator_access_opens_only_7681" {
  command = plan

  variables {
    enable_coordinator_access = true
    coordinator_ingress_cidrs = ["198.51.100.0/24"]
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.ssh_webpty) == 1 &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.ssh_webpty : rule.from_port == 22
      ]) &&
      length(aws_vpc_security_group_ingress_rule.coordinator) == 1 &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.coordinator :
        rule.from_port == 7681 && rule.to_port == 7681 && rule.cidr_ipv4 == "198.51.100.0/24"
      ])
    )
    error_message = "enable_coordinator_access must add only TCP 7681 using coordinator_ingress_cidrs."
  }
}
