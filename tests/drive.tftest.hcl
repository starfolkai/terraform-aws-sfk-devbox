mock_provider "aws" {}
mock_provider "random" {}
variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}
run "workspace_storage_has_scoped_roles_and_no_instance_grant" {
  command = apply
  override_resource {
    target = aws_iam_role.control
    values = { arn = "arn:aws:iam::123456789012:role/example-control" }
  }
  override_resource {
    target = aws_security_group.this
    values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
  }
  assert {
    condition     = aws_iam_role.drive.name == "sfk-drive-${substr(sha256(aws_iam_role.control.arn), 0, 16)}"
    error_message = "The broker and customer module must derive the same unique role name."
  }
  assert {
    condition     = jsondecode(aws_iam_role.drive.assume_role_policy).Statement[0].Principal.AWS == aws_iam_role.control.arn && jsondecode(aws_iam_role.drive.assume_role_policy).Statement[0].Condition.Null["aws:RequestTag/bucket_name"] == "false"
    error_message = "Only this control role may request tagged owner sessions."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.drive.policy).Statement[0].Resource[1] == "arn:aws:s3:::$${aws:PrincipalTag/bucket_name}/$${aws:PrincipalTag/workspace_id}/$${aws:PrincipalTag/user_id}/*" && !contains(jsondecode(aws_iam_role_policy.drive.policy).Statement[0].Action, "s3:DeleteObjectVersion")
    error_message = "Box sessions must retain workspace/user scope and version history."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.control.policy).Statement : s if try(s.Sid, "") == "PassDriveReplicationRole"]).Resource == aws_iam_role.drive_replication.arn
    error_message = "Control may pass only its own replication role."
  }
}


run "stage_aware_and_reserved_names_keep_owner_boundary" {
  command = plan
  variables { stage = "staging" }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_role_policy.drive.policy).Statement :
      toset(statement.Condition.StringLike["aws:PrincipalTag/bucket_name"]) == toset([
        "starfolk-drive-staging-workspace-$${aws:PrincipalTag/workspace_id}-*",
        "starfolk-drive-$${aws:PrincipalTag/workspace_id}-*",
      ])
    ])
    error_message = "All owner grants must admit this stage's workspace names and existing reservations."
  }
}

run "prod_names_are_bound_to_prod" {
  command = plan
  variables { stage = "prod" }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_role_policy.drive.policy).Statement :
      toset(statement.Condition.StringLike["aws:PrincipalTag/bucket_name"]) == toset([
        "starfolk-drive-prod-workspace-$${aws:PrincipalTag/workspace_id}-*",
        "starfolk-drive-$${aws:PrincipalTag/workspace_id}-*",
      ])
    ])
    error_message = "Production must not use a stage wildcard or lose already-reserved names."
  }
}
