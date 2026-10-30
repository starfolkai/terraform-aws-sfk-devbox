# New-box Drive storage stays in the customer's account. The name is derived
# identically by sfk's app/common/drive_storage.py; no new hand-back field.
locals {
  drive_role_suffix = substr(sha256(aws_iam_role.control.arn), 0, 16)
}

resource "aws_iam_role" "drive" {
  name = "sfk-drive-${local.drive_role_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.control.arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        Null = {
          "aws:RequestTag/workspace_id" = "false"
          "aws:RequestTag/user_id"      = "false"
          "aws:RequestTag/bucket_name"  = "false"
        }
        StringNotLike = {
          "aws:RequestTag/workspace_id" = ["*/*", ""]
          "aws:RequestTag/user_id"      = ["*/*", ""]
          "aws:RequestTag/bucket_name"  = ["*/*", ""]
        }
        "ForAllValues:StringEquals" = { "aws:TagKeys" = ["workspace_id", "user_id", "bucket_name"] }
      }
    }]
  })
  tags = merge({ owner = "starfolk-platform", purpose = "workspace Drive owner sessions" }, local.common_tags)
}

resource "aws_iam_role_policy" "drive" {
  role = aws_iam_role.drive.id
  name = "workspace-user-files"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = [
          "arn:aws:s3:::$${aws:PrincipalTag/bucket_name}/$${aws:PrincipalTag/workspace_id}/$${aws:PrincipalTag/user_id}",
          "arn:aws:s3:::$${aws:PrincipalTag/bucket_name}/$${aws:PrincipalTag/workspace_id}/$${aws:PrincipalTag/user_id}/*",
        ]
        Condition = { StringLike = { "aws:PrincipalTag/bucket_name" = "starfolk-drive-$${aws:PrincipalTag/workspace_id}-*" } }
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::$${aws:PrincipalTag/bucket_name}"
        Condition = { StringLike = {
          "aws:PrincipalTag/bucket_name" = "starfolk-drive-$${aws:PrincipalTag/workspace_id}-*"
          "s3:prefix"                    = ["$${aws:PrincipalTag/workspace_id}/$${aws:PrincipalTag/user_id}/*"]
        } }
      },
      {
        Effect    = "Allow"
        Action    = "s3:GetBucketLocation"
        Resource  = "arn:aws:s3:::$${aws:PrincipalTag/bucket_name}"
        Condition = { StringLike = { "aws:PrincipalTag/bucket_name" = "starfolk-drive-$${aws:PrincipalTag/workspace_id}-*" } }
      },
    ]
  })
}

resource "aws_iam_role" "drive_replication" {
  name = "sfk-drive-replication-${local.drive_role_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:s3:::starfolk-drive-*" }
      }
    }]
  })
  tags = merge({ owner = "starfolk-platform", purpose = "workspace Drive cross-region replication" }, local.common_tags)
}

resource "aws_iam_role_policy" "drive_replication" {
  role = aws_iam_role.drive_replication.id
  name = "workspace-bucket-replication"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetReplicationConfiguration", "s3:ListBucket"], Resource = "arn:aws:s3:::starfolk-drive-*" },
      { Effect = "Allow", Action = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"], Resource = "arn:aws:s3:::starfolk-drive-*/*" },
      { Effect = "Allow", Action = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"], Resource = "arn:aws:s3:::starfolk-drive-*-replica/*" },
    ]
  })
}
