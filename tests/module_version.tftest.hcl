mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
  tags = {
    "team"                    = "platform"
    "sfk:byoc_module_version" = "customer-override"
  }
}

run "security_group_reports_module_version" {
  command = apply
  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }

  assert {
    condition     = lookup(aws_security_group.this.tags, "sfk:byoc_module_version", null) == "v1.2.3"
    error_message = "The security group must report this release, even if customer tags try to override it."
  }
  assert {
    condition     = aws_security_group.this.tags["team"] == "platform" && aws_security_group.this.tags["sfk:byoc"] == "true"
    error_message = "Version reporting must preserve customer tags and the BYOC billing tag."
  }
}
