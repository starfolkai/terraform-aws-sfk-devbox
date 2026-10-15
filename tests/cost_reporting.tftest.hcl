mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
mock_provider "random" {}

# File-level: the SG's region postcondition needs a real ARN, and the bucket
# policy names the control role by ARN.
override_resource {
  target = aws_security_group.this
  values = { arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0" }
}

override_resource {
  target = aws_iam_role.control
  values = { arn = "arn:aws:iam::123456789012:role/sfk-devbox-control" }
}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
}

run "cost_reporting_is_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket.cost_report) == 0 && length(aws_bcmdataexports_export.cost_report) == 0
    error_message = "Cost reporting must create nothing unless enabled."
  }

  assert {
    condition     = output.cost_report_url == null
    error_message = "cost_report_url must be null when cost reporting is off."
  }
}

run "exports_everything_without_tags" {
  command = apply

  variables {
    enable_cost_reporting = true
  }

  assert {
    condition     = aws_s3_bucket.cost_report[0].bucket == "sfk-devbox-cost-report-123456789012"
    error_message = "Default bucket name must be <name_prefix>-cost-report-<account_id>."
  }

  assert {
    condition     = !strcontains(local.cost_report_query, "WHERE") && !strcontains(local.cost_report_query, "resource_tags")
    error_message = "The export must not filter, and must not export resource_tags."
  }

  assert {
    condition     = strcontains(local.cost_report_query, "line_item_resource_id")
    error_message = "The export must include resource ids; per-user attribution joins on them."
  }

  assert {
    condition     = aws_bcmdataexports_export.cost_report[0].export[0].data_query[0].table_configurations.COST_AND_USAGE_REPORT.INCLUDE_RESOURCES == "TRUE"
    error_message = "INCLUDE_RESOURCES must be TRUE."
  }

  assert {
    condition     = output.cost_report_url == "s3://sfk-devbox-cost-report-123456789012/starfolk/sfk-devbox-cost-report"
    error_message = "cost_report_url must point at the export's delivery path."
  }
}

run "query_is_pinned" {
  # The coordinator (starfolkai/sfk, EXPORT_COLUMNS in
  # coordinator/app/billing/byoc_cost_ingest.py) reads exactly these columns.
  # Changing this list must change this test, and then that one.
  command = plan

  variables {
    enable_cost_reporting = true
  }

  assert {
    condition     = local.cost_report_query == "SELECT identity_line_item_id, identity_time_interval, bill_billing_period_start_date, line_item_usage_start_date, line_item_usage_end_date, line_item_usage_account_id, line_item_line_item_type, line_item_product_code, line_item_usage_type, line_item_resource_id, line_item_usage_amount, line_item_unblended_cost, line_item_net_unblended_cost, pricing_public_on_demand_cost, pricing_term, savings_plan_savings_plan_effective_cost, savings_plan_amortized_upfront_commitment_for_billing_period, reservation_reservation_a_r_n, reservation_effective_cost, reservation_unused_amortized_upfront_fee_for_billing_period, reservation_unused_recurring_fee FROM COST_AND_USAGE_REPORT"
    error_message = "The export query changed; update EXPORT_COLUMNS in starfolkai/sfk to match."
  }
}

run "bucket_name_can_be_overridden" {
  command = apply

  variables {
    enable_cost_reporting   = true
    cost_report_bucket_name = "acme-starfolk-costs"
  }

  assert {
    condition     = aws_s3_bucket.cost_report[0].bucket == "acme-starfolk-costs"
    error_message = "cost_report_bucket_name must override the default."
  }
}

run "control_role_reads_only_the_prefix" {
  command = apply

  variables {
    enable_cost_reporting = true
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_s3_bucket_policy.cost_report[0].policy).Statement :
      alltrue([for a in flatten([s.Action]) : contains(["s3:GetObject", "s3:ListBucket"], a)])
      if s.Effect != "Deny" && s.Sid != "AllowDataExportsDelivery"
    ])
    error_message = "The control role may only GetObject/ListBucket."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_s3_bucket_policy.cost_report[0].policy).Statement : s.Resource
      if s.Sid == "StarfolkReadCostReport"
    ]) == "arn:aws:s3:::sfk-devbox-cost-report-123456789012/starfolk/*"
    error_message = "GetObject must be limited to the export prefix."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.cost_report[0].policy).Statement : s
      if s.Sid == "DenyInsecureTransport"
    ]) == 1
    error_message = "The bucket must deny non-TLS access."
  }
}
