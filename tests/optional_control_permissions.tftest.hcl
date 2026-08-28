mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "optional_control_permissions_are_present_by_default" {
  command = apply

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if contains([
        "CloudWatchReadMetrics",
        "EC2DescribeVolumes",
        "EC2ModifyTaggedVolumes",
      ], statement.Sid)
      ][*].Sid) == toset([
      "CloudWatchReadMetrics",
      "EC2DescribeVolumes",
      "EC2ModifyTaggedVolumes",
    ])
    error_message = "The CloudWatch metric and EC2 volume grants must both be present by default."
  }
}

run "cloudwatch_metrics_can_be_disabled_independently" {
  command = apply

  variables {
    enable_cloudwatch_read_metrics = false
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "CloudWatchReadMetrics"
    ]) == 0
    error_message = "Disabling CloudWatch metrics must remove the CloudWatchReadMetrics grant."
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if contains(["EC2DescribeVolumes", "EC2ModifyTaggedVolumes"], statement.Sid)
    ][*].Sid) == toset(["EC2DescribeVolumes", "EC2ModifyTaggedVolumes"])
    error_message = "Disabling CloudWatch metrics must not disable either EC2 volume statement."
  }
}

run "volume_changes_can_be_disabled_independently" {
  command = apply

  variables {
    enable_ec2_modify_tagged_volumes = false
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "EC2ModifyTaggedVolumes"
    ]) == 0
    error_message = "Disabling volume changes must remove the EC2ModifyTaggedVolumes grant."
  }

  # The reads are not part of the switch: a customer who declines resizes still
  # sees their boxes' disk sizes in the dashboard.
  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "EC2DescribeVolumes"
      ]) == {
      Action   = ["ec2:DescribeVolumes", "ec2:DescribeVolumesModifications"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "EC2DescribeVolumes"
    }
    error_message = "Disabling volume changes must not disable the read-only volume describes."
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
    error_message = "Disabling volume changes must not disable CloudWatch metric reads."
  }
}
