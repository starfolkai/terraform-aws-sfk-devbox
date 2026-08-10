mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-2a"]
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id  = "sg-0123456789abcdef0"
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }
}

mock_provider "random" {
  override_during = plan
}

variables {
  vpc_id         = "vpc-0123456789abcdef0"
  subnet_cidrs   = ["10.0.0.0/24"]
  route_table_id = "rtb-0123456789abcdef0"
}

run "prod_web_sessions_are_opt_in" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.coordinator) == 0
    error_message = "Port 7681 must remain closed by default."
  }
}

run "prod_web_sessions_allow_only_the_prod_nat_eip" {
  command = plan

  variables {
    enable_prod_coordinator_web_sessions = true
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.coordinator)) == toset(["18.188.161.41/32"])
    error_message = "The production opt-in must create exactly one rule for the production NAT EIP."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.coordinator["18.188.161.41/32"].from_port == 7681
    error_message = "The production coordinator rule must open DEVBOX_PORT 7681."
  }
}

run "custom_web_sessions_require_explicit_cidrs" {
  command = plan

  variables {
    enable_web_sessions = true
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.coordinator) == 0
    error_message = "A custom web-session opt-in without CIDRs must not expose port 7681."
  }
}

run "custom_coordinator_cidrs_remain_supported" {
  command = plan

  variables {
    enable_web_sessions       = true
    coordinator_ingress_cidrs = ["203.0.113.10/32"]
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.coordinator)) == toset(["203.0.113.10/32"])
    error_message = "Custom coordinator CIDRs must remain available for non-production coordinators."
  }
}
