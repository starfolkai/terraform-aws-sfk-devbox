# The values to hand back to Starfolk (they land in the workspace's
# cloud_accounts row). `handback` collects them into one object; the rest are
# the same values one at a time.

locals {
  cost_report_url = var.enable_cost_reporting ? "s3://${aws_s3_bucket.cost_report[0].bucket}/${local.cost_report_prefix}/${local.cost_report_name}" : null
}

output "handback" {
  value = {
    account_id        = local.account_id
    access_mode       = local.access_mode
    region            = var.region
    role_arn          = aws_iam_role.control.arn
    external_id       = local.external_id
    subnet_ids        = local.subnet_ids_effective
    security_group_id = aws_security_group.this.id
    instance_profile  = local.instance_profile_name
    cost_report_url   = local.cost_report_url
    module_version    = local.module_version
  }
  description = "Everything Starfolk needs, as one object. Register it with `sfk cloud-account register`, or paste it into Settings → AWS Account."
}

output "module_version" {
  value       = local.module_version
  description = "Release tag of this module, e.g. v1.3.0."
}

output "account_id" {
  value       = local.account_id
  description = "Customer AWS account ID."
}

output "access_mode" {
  # Derived from assign_public_ip so the handback tells Starfolk how boxes here
  # are reached — no guessing at registration time. "public" = subnets auto-assign
  # public IPs (posture A/A-VPN); "vpn_private" = no public IP, boxes reached by
  # their private VPC IP over your VPN (posture B). (Nebula-overlay posture C also
  # sets assign_public_ip=false but is addressed via the overlay, not the private
  # IP — if you use the overlay rather than a VPN, tell Starfolk to register it
  # differently.) Register the cloud account with this access_mode.
  value       = local.access_mode
  description = "How boxes here are reached: 'public' (public IP) or 'vpn_private' (no public IP, private IP over your VPN). Register the cloud account with this value."
}

output "region" {
  value       = var.region
  description = "Supported region selected for these resources and its regional shared-AMI KMS grant."
}

output "role_arn" {
  value       = aws_iam_role.control.arn
  description = "The control role the Starfolk coordinator assumes."
}

output "external_id" {
  value       = local.external_id
  description = "External ID for the control-role trust. Not a secret (a confused-deputy guard) — send it back to Starfolk."
}

output "subnet_ids" {
  value       = local.subnet_ids_effective
  description = "The dedicated SFK devbox subnet IDs."
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "The dedicated SFK devbox security group ID."
}

output "instance_profile" {
  value       = local.instance_profile_name
  description = "The devbox instance profile name (module-created, or your bring-your-own value)."
}

output "cost_report_url" {
  value       = local.cost_report_url
  description = "Where the cost export lands (s3://bucket/prefix/export-name). Send it to Starfolk along with role_arn. Null when enable_cost_reporting = false."
}
