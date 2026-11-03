# The provider has default_tags; the module's `tags` should repeat them, or
# plan warns that the boxes Starfolk creates won't carry them.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_default_tags" {
    defaults = { tags = { "cost-center" = "x", "env" = "prod", "sfk:byoc" = "true", "Name" = "n" } }
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

run "warns_when_default_tags_are_missing_from_tags" {
  command = plan

  variables {
    tags = { "cost-center" = "x" }
  }

  expect_failures = [check.default_tags_not_sent_to_starfolk]
}

run "quiet_when_tags_repeat_them" {
  command = plan

  # sfk: keys and Name are Starfolk's, so they needn't be repeated.
  variables {
    tags = { "cost-center" = "x", "env" = "prod" }
  }
}
