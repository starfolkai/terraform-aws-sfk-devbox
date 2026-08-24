# The values to hand back to Starfolk (they land in the workspace's
# cloud_accounts row). `terraform output -json` gives a clean payload.

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

output "session_archive_bucket" {
  # Echoed back so the hand-back payload carries it: Starfolk archives each
  # terminated session's log to this bucket, and deletes the content with no copy
  # when it is empty. Registering it is what turns the archive on — the IAM grant
  # existing is not enough on its own.
  value       = var.session_archive_bucket
  description = "Bucket terminated sessions' agent logs are archived to; empty means the content is deleted instead."
}

output "session_archive_prefix" {
  value       = local.session_archive_prefix_clean
  description = "Key preamble inside session_archive_bucket (normalized, no leading/trailing slash)."
}
