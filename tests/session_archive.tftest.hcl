# The session-log archive grant is write-only, and "write-only" is the whole
# security claim of the feature — so it is asserted here rather than trusted to
# review. Also asserts the absent case: with no bucket named, the control policy
# must be byte-identical to a module that has never heard of S3.

mock_provider "aws" {}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "no_bucket_emits_no_s3_statement" {
  command = plan

  assert {
    condition     = length(local.control_session_archive_statements) == 0
    error_message = "With session_archive_bucket unset the control policy must contain no S3 statement at all."
  }
}

run "bucket_grants_put_only" {
  command = plan

  variables {
    session_archive_bucket = "acme-starfolk-session-logs"
  }

  assert {
    condition     = length(local.control_session_archive_statements) == 1
    error_message = "Naming a bucket must add exactly one S3 statement."
  }

  # The claim customers are asked to accept: Starfolk can put objects here and
  # cannot read, list, or delete them.
  assert {
    condition = alltrue([
      for statement in local.control_session_archive_statements :
      alltrue([for action in statement.Action : contains(["s3:PutObject", "s3:AbortMultipartUpload"], action)])
    ])
    error_message = "The session-archive grant must allow only PutObject and AbortMultipartUpload — no GetObject, ListBucket, or delete."
  }

  # A bucket-wide grant when no prefix is given, scoped to objects (never the
  # bucket itself, which is what ListBucket would need).
  assert {
    condition = alltrue([
      for statement in local.control_session_archive_statements :
      statement.Resource == "arn:aws:s3:::acme-starfolk-session-logs/*"
    ])
    error_message = "With no prefix the grant must cover every object in the named bucket, and nothing else."
  }
}

run "prefix_narrows_the_grant_and_normalizes_slashes" {
  command = plan

  variables {
    session_archive_bucket = "acme-shared-bucket"
    # Leading and trailing slashes are accepted and normalized, so a customer
    # cannot accidentally produce `bucket//starfolk//*` — which would match
    # nothing and silently deny every archive write.
    session_archive_prefix = "/starfolk/logs/"
  }

  assert {
    condition = alltrue([
      for statement in local.control_session_archive_statements :
      statement.Resource == "arn:aws:s3:::acme-shared-bucket/starfolk/logs/*"
    ])
    error_message = "A prefix must narrow the grant to that prefix, with slashes normalized."
  }
}
