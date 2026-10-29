mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "archive_disk_cleanup_permission_is_volume_scoped" {
  command = apply
  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s
      if try(s.Sid, "") == "EC2ArchiveVolumeTermination"
      ]) == {
      Sid       = "EC2ArchiveVolumeTermination"
      Effect    = "Allow"
      Action    = ["ec2:ModifyInstanceAttribute"]
      Resource  = "arn:aws:ec2:*:*:volume/*"
      Condition = { StringEquals = { "aws:ResourceTag/sfk:prod:managed" = "true" } }
    }
    error_message = "Archive finalization needs only ModifyInstanceAttribute on stage-managed volumes."
  }
}

run "archive_disk_cleanup_uses_customer_stage" {
  command = apply
  variables {
    stage                            = "staging"
    enable_ec2_modify_tagged_volumes = false
  }
  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s.Condition
      if try(s.Sid, "") == "EC2ArchiveVolumeTermination"
    ]) == { StringEquals = { "aws:ResourceTag/sfk:staging:managed" = "true" } }
    error_message = "The volume permission must use the configured stage, never a fixed prod tag."
  }
}
