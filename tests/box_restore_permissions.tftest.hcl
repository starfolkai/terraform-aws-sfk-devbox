mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
  stage              = "prod"
  # Include opt-in image-tagging grants in the no-volume-retagging check.
  enable_ec2_image_snapshots = true
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
      Action   = ["ec2:AttachVolume", "ec2:DetachVolume"]
      Resource = "arn:aws:ec2:*:*:volume/*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/sfk:prod:managed" = "true"
          "aws:ResourceTag/sfk:purpose"      = "box-restore"
        }
        Null = { "aws:ResourceTag/sfk:box-restore" = "false" }
      }
    }
    error_message = "Only positively tagged restore disks can be attached or detached."
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
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s
      if s.Sid == "EC2DeleteRestoreTemporaryVolumes"
      ]) == {
      Sid      = "EC2DeleteRestoreTemporaryVolumes"
      Effect   = "Allow"
      Action   = ["ec2:DeleteVolume"]
      Resource = "arn:aws:ec2:*:*:volume/*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/sfk:prod:managed"     = "true"
          "aws:ResourceTag/sfk:purpose"          = "box-restore"
          "aws:ResourceTag/sfk:box-restore-role" = "temporary-root"
        }
        Null = { "aws:ResourceTag/sfk:box-restore" = "false" }
      }
    }
    error_message = "Only the exact tag-gated temporary-volume delete grant is allowed."
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s
      if s.Sid == "EC2AttachRestoreInstances"
      ]) == {
      Sid      = "EC2AttachRestoreInstances"
      Effect   = "Allow"
      Action   = ["ec2:AttachVolume", "ec2:DetachVolume"]
      Resource = "arn:aws:ec2:*:*:instance/*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/sfk:prod:managed" = "true"
          "aws:ResourceTag/sfk:purpose"      = "box-restore"
        }
        Null = { "aws:ResourceTag/sfk:box-restore" = "false" }
      }
    }
    error_message = "Attach/detach must authorize only positively tagged restore instances."
  }
  assert {
    # Creating tags on an existing saved volume would bypass the delete gate.
    # Outside resource creation, tagging must therefore remain instance-only.
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.control.policy).Statement :
      try(length(s.Condition.StringEquals["ec2:CreateAction"]) > 0, false) ||
      flatten([s.Resource]) == ["arn:aws:ec2:*:*:instance/*"]
      if s.Effect == "Allow" && anytrue([
        for action in flatten([s.Action]) :
        can(regex("^${replace(replace(lower(action), "*", ".*"), "?", ".")}$", "ec2:createtags"))
      ])
    ])
    error_message = "CreateTags grants must require resource creation or apply only to instances; existing volumes cannot be retagged."
  }
}
