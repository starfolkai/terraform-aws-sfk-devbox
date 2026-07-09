# The seven values to hand back to Starfolk (they land in the workspace's
# cloud_accounts row). `terraform output -json` gives a clean payload.

output "account_id" {
  value       = local.account_id
  description = "Customer AWS account ID."
}

output "region" {
  value       = local.region
  description = "Region these resources were created in."
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
  value       = aws_subnet.this[*].id
  description = "The dedicated SFK devbox subnet IDs."
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "The dedicated SFK devbox security group ID."
}

output "instance_profile" {
  value       = aws_iam_instance_profile.devbox.name
  description = "The devbox instance profile name."
}
