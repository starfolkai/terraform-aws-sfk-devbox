# The tag-gated instance-management grant is the statement that has to stay in
# step with the coordinator's own two policies (`account-terraform/module/iam.tf`
# and `serving-terraform/module-ecs/coordinator-ec2-policy.json.tftpl` in
# starfolkai/sfk). Nothing in either repo can see the other, so pin the whole
# statement here: an action added there and forgotten here is the failure mode.

mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "tagged_instance_management_grant_is_pinned" {
  command = apply

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "EC2ManageTaggedInstances"
      ]) == {
      Sid    = "EC2ManageTaggedInstances"
      Effect = "Allow"
      Action = [
        "ec2:TerminateInstances", "ec2:StopInstances", "ec2:StartInstances",
        "ec2:RebootInstances",
        "ec2:CreateTags", "ec2:DeleteTags", "ec2:ModifyInstanceAttribute",
      ]
      Resource  = "arn:aws:ec2:*:*:instance/*"
      Condition = { StringEquals = { "aws:ResourceTag/sfk:prod:managed" = "true" } }
    }
    error_message = "EC2ManageTaggedInstances must grant exactly the coordinator's tag-gated instance actions, on instance/* only."
  }
}

run "the_tag_gate_follows_the_stage" {
  command = apply

  variables {
    stage = "staging"
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  # Reboot is destructive enough to belong inside the tag gate, not beside it:
  # an untagged instance in the customer's account must not be reachable.
  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.control.policy).Statement : statement
      if statement.Sid == "EC2ManageTaggedInstances"
    ]).Condition == { StringEquals = { "aws:ResourceTag/sfk:staging:managed" = "true" } }
    error_message = "The instance-management grant must stay gated on the sfk:<stage>:managed tag."
  }
}
