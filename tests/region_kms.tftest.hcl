mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "default_us_east_2_uses_east_key" {
  command = plan

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = alltrue([
      for statement in local.control_kms_statements :
      length(statement.Resource) == 1 && statement.Resource[0] == "arn:aws:kms:us-east-2:450410490644:key/4bcb6251-1960-46ca-859e-3a5f24757caa"
    ])
    error_message = "The us-east-2 control policy must grant only the us-east-2 shared-AMI KMS key."
  }
}

run "us_west_2_uses_west_key" {
  command = plan

  variables {
    region             = "us-west-2"
    availability_zones = ["us-west-2a"]
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-west-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = alltrue([
      for statement in local.control_kms_statements :
      length(statement.Resource) == 1 && statement.Resource[0] == "arn:aws:kms:us-west-2:450410490644:key/e661422c-3f6e-426f-a8d3-434f64deab8a"
    ])
    error_message = "The us-west-2 control policy must grant only the us-west-2 shared-AMI KMS key."
  }
}

run "unsupported_region_fails" {
  command = plan

  variables {
    region = "eu-west-1"
  }

  expect_failures = [var.region]
}

run "us_west_2_rejects_east_key_override" {
  command = plan

  variables {
    region             = "us-west-2"
    availability_zones = ["us-west-2a"]
    ami_kms_key_arns   = ["arn:aws:kms:us-east-2:450410490644:key/4bcb6251-1960-46ca-859e-3a5f24757caa"]
  }

  expect_failures = [var.ami_kms_key_arns]
}

run "us_west_2_accepts_west_key_override" {
  command = plan

  variables {
    region             = "us-west-2"
    availability_zones = ["us-west-2a"]
    ami_kms_key_arns   = ["arn:aws:kms:us-west-2:450410490644:key/e661422c-3f6e-426f-a8d3-434f64deab8a"]
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-west-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }
}

run "provider_region_mismatch_fails" {
  command = apply

  variables {
    region             = "us-west-2"
    availability_zones = ["us-west-2a"]
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  expect_failures = [aws_security_group.this]
}
