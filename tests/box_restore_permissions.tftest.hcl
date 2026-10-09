mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
  stage              = "prod"
}

run "restore_permissions_require_positive_tags" {
  command = apply
  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s
      if s.Sid == "EC2ManageRestoreVolumes"
      ]) == {
      Sid      = "EC2ManageRestoreVolumes"
      Effect   = "Allow"
      Action   = ["ec2:AttachVolume", "ec2:DetachVolume", "ec2:DeleteVolume"]
      Resource = "arn:aws:ec2:*:*:volume/*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/sfk:prod:managed" = "true"
          "aws:ResourceTag/sfk:purpose"      = "box-restore"
        }
        Null = { "aws:ResourceTag/sfk:box-restore" = "false" }
      }
    }
    error_message = "Only tagged restore volumes can be detached, attached or deleted."
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s.Condition
      if s.Sid == "EC2RestoreFromRecoverySnapshots"
      ]) == {
      StringEquals = { "aws:ResourceTag/sfk:purpose" = "box-recovery" }
      Null         = { "aws:ResourceTag/sfk:box-archive" = "false" }
    }
    error_message = "New volumes must come from archived recovery snapshots."
  }
}
