mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "optional_control_permissions_are_absent_by_default" {
  command = apply

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if contains([
        "CloudWatchReadMetrics",
        "EC2DescribeVolumes",
        "EC2ModifyTaggedVolumes",
      ], statement.Sid)
    ]) == 0
    error_message = "The CloudWatch metric and EC2 volume grants must both be absent by default."
  }
}

run "cloudwatch_metrics_can_be_enabled_independently" {
  command = apply

  variables {
    enable_cloudwatch_read_metrics = true
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "CloudWatchReadMetrics"
      ]) == {
      Action   = ["cloudwatch:GetMetricData"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "CloudWatchReadMetrics"
    }
    error_message = "enable_cloudwatch_read_metrics must add only the CloudWatchReadMetrics grant."
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if contains(["EC2DescribeVolumes", "EC2ModifyTaggedVolumes"], statement.Sid)
    ]) == 0
    error_message = "Enabling CloudWatch metrics must not enable either EC2 volume statement."
  }
}

run "volume_changes_can_be_enabled_independently" {
  command = apply

  variables {
    enable_ec2_modify_tagged_volumes = true
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = toset(one([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement.Action
      if statement.Sid == "EC2DescribeVolumes"
    ])) == toset(["ec2:DescribeVolumes", "ec2:DescribeVolumesModifications"])
    error_message = "The volume switch must add both read-only EC2 volume description actions."
  }

  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "EC2ModifyTaggedVolumes"
    ]).Condition.StringEquals["aws:ResourceTag/sfk:prod:managed"] == "true"
    error_message = "ModifyVolume must remain scoped to SFK-managed volumes for the configured stage."
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "CloudWatchReadMetrics"
    ]) == 0
    error_message = "Enabling volume changes must not enable CloudWatch metric reads."
  }
}
