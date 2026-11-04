mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
mock_provider "random" {}

override_resource {
  target = aws_security_group.this
  values = {
    id  = "sg-0123456789abcdef0"
    arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
  }
}

override_resource {
  target = aws_iam_role.control
  values = { arn = "arn:aws:iam::123456789012:role/sfk-devbox-control" }
}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
  external_id        = "sfk-test"
}

run "handback_carries_everything_starfolk_registers" {
  command = apply

  assert {
    condition = alltrue([
      for k in ["account_id", "access_mode", "region", "role_arn", "external_id", "subnet_ids", "security_group_id", "instance_profile", "cost_report_url", "module_version"] :
      contains(keys(output.handback), k)
    ])
    error_message = "handback is missing a field Starfolk registers."
  }

  assert {
    condition     = output.handback.account_id == "123456789012" && output.handback.external_id == "sfk-test"
    error_message = "handback must carry the account and external ID."
  }

  assert {
    condition     = output.handback.cost_report_url == null
    error_message = "cost_report_url must be null when cost reporting is off."
  }
}

run "module_version_is_a_release_tag" {
  command = plan

  assert {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", output.module_version))
    error_message = "module_version must look like v1.2.3: Starfolk refuses anything else."
  }

  assert {
    condition     = output.handback.module_version == output.module_version
    error_message = "handback must carry module_version."
  }
}
