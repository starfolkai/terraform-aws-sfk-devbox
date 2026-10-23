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
      Action   = ["ec2:DescribeVolumes", "ec2:DescribeVolumesModifications", "ec2:DescribeSnapshots"]
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

run "image_snapshots_are_off_by_default" {
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
        "EC2SnapshotManagedVolumes",
        "EC2CreateManagedSnapshots",
        "EC2TagSnapshotsOnCreate",
        "EC2RegisterManagedImages",
        "EC2RegisterImagesFromManagedSnapshots",
        "EC2TagImagesOnRegister",
        "EC2DeregisterManagedImages",
        "EC2DeleteManagedSnapshots",
      ], statement.Sid)
    ]) == 0
    error_message = "Image regeneration grants must be opt-in (box recovery's are separate)."
  }
}

run "image_regeneration_stays_in_account" {
  command = apply

  variables {
    enable_ec2_image_snapshots = true
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement.Sid
      if contains([
        "EC2SnapshotManagedVolumes",
        "EC2CreateManagedSnapshots",
        "EC2TagSnapshotsOnCreate",
        "EC2RegisterManagedImages",
        "EC2RegisterImagesFromManagedSnapshots",
        "EC2TagImagesOnRegister",
        "EC2DeregisterManagedImages",
        "EC2DeleteManagedSnapshots",
      ], statement.Sid)
      ]) == toset([
      "EC2SnapshotManagedVolumes",
      "EC2CreateManagedSnapshots",
      "EC2TagSnapshotsOnCreate",
      "EC2RegisterManagedImages",
      "EC2RegisterImagesFromManagedSnapshots",
      "EC2TagImagesOnRegister",
      "EC2DeregisterManagedImages",
      "EC2DeleteManagedSnapshots",
    ])
    error_message = "Enabling image snapshots must grant the full snapshot-and-register set."
  }

  # Nothing leaves the account: no statement may share a snapshot or image.
  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if length(setintersection(
        toset(flatten([statement.Action])),
        toset(["ec2:ModifySnapshotAttribute", "ec2:ModifyImageAttribute"]),
      )) > 0
    ]) == 0
    error_message = "Image regeneration must not grant sharing snapshots or images out of the account."
  }

  # Each statement exactly: a wrong condition key (say, ResourceTag on the image
  # RegisterImage creates) would deny every real call, and nothing else here
  # evaluates the policy.
  assert {
    condition = {
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement :
      statement.Sid => statement
      if contains([
        "EC2SnapshotManagedVolumes",
        "EC2CreateManagedSnapshots",
        "EC2TagSnapshotsOnCreate",
        "EC2RegisterManagedImages",
        "EC2RegisterImagesFromManagedSnapshots",
        "EC2TagImagesOnRegister",
        "EC2DeregisterManagedImages",
        "EC2DeleteManagedSnapshots",
      ], statement.Sid)
      } == {
      EC2SnapshotManagedVolumes = {
        Sid       = "EC2SnapshotManagedVolumes"
        Effect    = "Allow"
        Action    = ["ec2:CreateSnapshot"]
        Resource  = "arn:aws:ec2:*:*:volume/*"
        Condition = { StringEquals = { "aws:ResourceTag/sfk:prod:managed" = "true" } }
      }
      EC2CreateManagedSnapshots = {
        Sid       = "EC2CreateManagedSnapshots"
        Effect    = "Allow"
        Action    = ["ec2:CreateSnapshot"]
        Resource  = "arn:aws:ec2:*::snapshot/*"
        Condition = { StringEquals = { "aws:RequestTag/sfk:prod:managed" = "true" } }
      }
      EC2TagSnapshotsOnCreate = {
        Sid       = "EC2TagSnapshotsOnCreate"
        Effect    = "Allow"
        Action    = ["ec2:CreateTags"]
        Resource  = "arn:aws:ec2:*::snapshot/*"
        Condition = { StringEquals = { "ec2:CreateAction" = "CreateSnapshot" } }
      }
      EC2RegisterManagedImages = {
        Sid       = "EC2RegisterManagedImages"
        Effect    = "Allow"
        Action    = ["ec2:RegisterImage"]
        Resource  = "arn:aws:ec2:*::image/*"
        Condition = { StringEquals = { "aws:RequestTag/sfk:prod:managed" = "true" } }
      }
      EC2RegisterImagesFromManagedSnapshots = {
        Sid       = "EC2RegisterImagesFromManagedSnapshots"
        Effect    = "Allow"
        Action    = ["ec2:RegisterImage"]
        Resource  = "arn:aws:ec2:*::snapshot/*"
        Condition = { StringEquals = { "aws:ResourceTag/sfk:prod:managed" = "true" } }
      }
      EC2TagImagesOnRegister = {
        Sid       = "EC2TagImagesOnRegister"
        Effect    = "Allow"
        Action    = ["ec2:CreateTags"]
        Resource  = "arn:aws:ec2:*::image/*"
        Condition = { StringEquals = { "ec2:CreateAction" = "RegisterImage" } }
      }
      EC2DeregisterManagedImages = {
        Sid       = "EC2DeregisterManagedImages"
        Effect    = "Allow"
        Action    = ["ec2:DeregisterImage"]
        Resource  = "arn:aws:ec2:*::image/*"
        Condition = { StringEquals = { "aws:ResourceTag/sfk:prod:managed" = "true" } }
      }
      EC2DeleteManagedSnapshots = {
        Sid       = "EC2DeleteManagedSnapshots"
        Effect    = "Allow"
        Action    = ["ec2:DeleteSnapshot"]
        Resource  = "arn:aws:ec2:*::snapshot/*"
        Condition = { StringEquals = { "aws:ResourceTag/sfk:prod:managed" = "true" } }
      }
    }
    error_message = "Each image regeneration statement must have exactly its action, resource, and tag condition."
  }
}
