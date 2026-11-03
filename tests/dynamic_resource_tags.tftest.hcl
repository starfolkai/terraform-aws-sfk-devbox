mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
mock_provider "random" {}

override_resource {
  target = aws_security_group.this
  values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "empty_by_default" {
  command = plan

  assert {
    condition     = length(output.dynamic_resource_tags) == 0
    error_message = "dynamic_resource_tags must default to an empty map."
  }
}

run "emitted_in_the_handback_from_tags" {
  command = plan

  variables {
    tags = { "cost-center" = "eng tools", "team:owner" = "platform@acme.com" }
  }

  assert {
    condition     = output.dynamic_resource_tags == tomap({ "cost-center" = "eng tools", "team:owner" = "platform@acme.com" })
    error_message = "dynamic_resource_tags must carry tags unchanged."
  }

  assert {
    condition     = aws_security_group.this.tags["cost-center"] == "eng tools"
    error_message = "tags must still reach module-created resources."
  }
}

run "leaves_out_starfolk_keys" {
  command = plan

  variables {
    tags = { "cost-center" = "x", "SFK:workspace_id" = "1", "Name" = "mine" }
  }

  assert {
    condition     = output.dynamic_resource_tags == tomap({ "cost-center" = "x" })
    error_message = "sfk: keys and Name must not reach the hand-back."
  }
}
