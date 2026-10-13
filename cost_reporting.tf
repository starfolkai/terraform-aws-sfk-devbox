# ── Optional cost reporting (AWS cost of Starfolk resources → Starfolk) ──────
# Created only when enable_cost_reporting = true (default false). An AWS Data
# Export (CUR 2.0) writes this account's hourly cost and usage into a private
# bucket here; the control role may read that one prefix and nothing else.
# Starfolk ingests it to show the AWS cost of your boxes per environment and
# per user. It is informational: nothing here feeds a Starfolk invoice.
#
# cost_reporting_scope picks what the export contains:
#   "account" — every cost line in this account. Use when the account is
#               dedicated to Starfolk. No tag activation needed: AWS limits an
#               export made in a member account to that account's own costs.
#   "tagged"  — only lines whose resource carries sfk:stage = var.stage. For a
#               shared account. Needs sfk:stage (and sfk:workspace_id,
#               sfk:environment_id) activated as cost-allocation tags in the
#               account that pays your AWS bill; until then the export is empty.
#
# Either way only the columns Starfolk reads are exported, and `resource_tags`
# only in "tagged" mode, so your own tag values on unrelated resources never
# leave the account.

locals {
  cost_reporting      = var.enable_cost_reporting
  cost_report_bucket  = var.cost_report_bucket_name != "" ? var.cost_report_bucket_name : "${var.name_prefix}-cost-report-${local.account_id}"
  cost_report_prefix  = trim(var.cost_report_prefix, "/")
  cost_report_name    = "${var.name_prefix}-cost-report"
  cost_report_bkt_arn = "arn:aws:s3:::${local.cost_report_bucket}"

  # Exactly the CUR 2.0 columns Starfolk's ingester reads. Keep in sync with
  # coordinator/app/billing/billing_ingest_aws.py in starfolkai/sfk.
  cost_report_columns = concat([
    "identity_line_item_id",
    "identity_time_interval",
    "bill_billing_period_start_date",
    "line_item_usage_start_date",
    "line_item_usage_end_date",
    "line_item_usage_account_id",
    "line_item_line_item_type",
    "line_item_product_code",
    "line_item_usage_type",
    "line_item_resource_id",
    "line_item_usage_amount",
    "line_item_unblended_cost",
    "line_item_net_unblended_cost",
    "pricing_public_on_demand_cost",
    "pricing_term",
    "savings_plan_savings_plan_effective_cost",
    "savings_plan_amortized_upfront_commitment_for_billing_period",
  ], var.cost_reporting_scope == "tagged" ? ["resource_tags"] : [])

  cost_report_where = var.cost_reporting_scope == "tagged" ? " WHERE resource_tags.user_sfk_stage = '${var.stage}'" : ""
  cost_report_query = "SELECT ${join(", ", local.cost_report_columns)} FROM COST_AND_USAGE_REPORT${local.cost_report_where}"
}

resource "aws_s3_bucket" "cost_report" {
  count         = local.cost_reporting ? 1 : 0
  bucket        = local.cost_report_bucket
  force_destroy = var.cost_report_bucket_force_destroy
  tags          = merge(local.common_tags, { "sfk:purpose" = "cost-report" })
}

resource "aws_s3_bucket_ownership_controls" "cost_report" {
  count  = local.cost_reporting ? 1 : 0
  bucket = aws_s3_bucket.cost_report[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cost_report" {
  count                   = local.cost_reporting ? 1 : 0
  bucket                  = aws_s3_bucket.cost_report[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cost_report" {
  count  = local.cost_reporting ? 1 : 0
  bucket = aws_s3_bucket.cost_report[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "cost_report" {
  count  = local.cost_reporting ? 1 : 0
  bucket = aws_s3_bucket.cost_report[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# Each refresh writes a new full copy of the month (CREATE_NEW_REPORT), so old
# deliveries pile up. Keep a bit over a year by default.
resource "aws_s3_bucket_lifecycle_configuration" "cost_report" {
  count  = local.cost_reporting ? 1 : 0
  bucket = aws_s3_bucket.cost_report[0].id

  rule {
    id     = "expire-old-deliveries"
    status = "Enabled"
    filter {}
    expiration {
      days = var.cost_report_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.cost_report]
}

resource "aws_s3_bucket_policy" "cost_report" {
  count  = local.cost_reporting ? 1 : 0
  bucket = aws_s3_bucket.cost_report[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Lets AWS Data Exports deliver, but only exports owned by this account.
        Sid       = "AllowDataExportsDelivery"
        Effect    = "Allow"
        Principal = { Service = ["billingreports.amazonaws.com", "bcm-data-exports.amazonaws.com"] }
        Action    = ["s3:PutObject", "s3:GetBucketPolicy"]
        Resource  = [local.cost_report_bkt_arn, "${local.cost_report_bkt_arn}/*"]
        Condition = {
          StringLike = {
            "aws:SourceAccount" = local.account_id
            "aws:SourceArn" = [
              "arn:aws:cur:us-east-1:${local.account_id}:definition/*",
              "arn:aws:bcm-data-exports:us-east-1:${local.account_id}:export/*",
            ]
          }
        }
      },
      {
        Sid       = "StarfolkReadCostReport"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.control.arn }
        Action    = ["s3:GetObject"]
        Resource  = "${local.cost_report_bkt_arn}/${local.cost_report_prefix}/*"
      },
      {
        Sid       = "StarfolkListCostReport"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.control.arn }
        Action    = ["s3:ListBucket"]
        Resource  = local.cost_report_bkt_arn
        Condition = { StringLike = { "s3:prefix" = ["${local.cost_report_prefix}/*"] } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.cost_report_bkt_arn, "${local.cost_report_bkt_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cost_report]
}

# Data Exports is a global (us-east-1) API; the provider routes it there
# regardless of var.region. The bucket itself stays in var.region.
resource "aws_bcmdataexports_export" "cost_report" {
  count = local.cost_reporting ? 1 : 0

  export {
    name = local.cost_report_name
    # Static on purpose: description changes force the provider to replace the
    # export, and switching cost_reporting_scope should be an in-place query edit.
    description = "Starfolk: AWS cost of Starfolk-managed resources"

    data_query {
      query_statement = local.cost_report_query
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          BILLING_VIEW_ARN                      = "arn:aws:billing::${local.account_id}:billingview/primary"
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "FALSE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cost_report[0].bucket
        s3_prefix = local.cost_report_prefix
        s3_region = var.region
        s3_output_configurations {
          overwrite   = "CREATE_NEW_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  tags = local.common_tags

  # Data Exports checks the bucket policy at create time.
  depends_on = [aws_s3_bucket_policy.cost_report]
}
