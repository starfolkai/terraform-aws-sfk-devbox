mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "control_role_can_create_only_starfolk_buckets" {
  command = apply

  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }

  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "CreateStarfolkBuckets"
      ]) == {
      Sid      = "CreateStarfolkBuckets"
      Effect   = "Allow"
      Action   = ["s3:CreateBucket"]
      Resource = "arn:aws:s3:::starfolk*"
    }
    error_message = "The control role must allow only CreateBucket on the lowercase starfolk prefix, without object or delete grants."
  }
}
