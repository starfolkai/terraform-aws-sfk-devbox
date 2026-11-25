mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "prod_box_identity" {
  command = apply
  variables { stage = "prod" }
  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s
      if s.Sid == "ReadManagedBoxEndorsementKey"
      ]) == {
      Sid       = "ReadManagedBoxEndorsementKey"
      Effect    = "Allow"
      Action    = ["ec2:GetInstanceTpmEkPub"]
      Resource  = "arn:aws:ec2:*:123456789012:instance/*"
      Condition = { StringEquals = { "aws:ResourceTag/sfk:prod:managed" = "true" } }
    }
    error_message = "TPM identity reads must stay in the customer's account and deployment."
  }
}
run "staging_box_identity" {
  command = apply
  variables { stage = "staging" }
  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s
      if s.Sid == "ReadManagedBoxEndorsementKey"
      ]) == {
      Sid       = "ReadManagedBoxEndorsementKey"
      Effect    = "Allow"
      Action    = ["ec2:GetInstanceTpmEkPub"]
      Resource  = "arn:aws:ec2:*:123456789012:instance/*"
      Condition = { StringEquals = { "aws:ResourceTag/sfk:staging:managed" = "true" } }
    }
    error_message = "TPM identity reads must stay in the customer's account and deployment."
  }
}
