variable "vpc_id" {
  type        = string
  description = "Existing (shared) VPC to place the dedicated SFK devbox subnets in. This module never creates a VPC — it expresses its requirements against yours."
}

variable "subnet_cidrs" {
  type        = list(string)
  description = "One CIDR per AZ for the dedicated SFK devbox subnets, chosen from free space in your VPC. One subnet is created per entry."

  validation {
    condition     = length(var.subnet_cidrs) >= 1
    error_message = "Provide at least one subnet CIDR."
  }
}

variable "availability_zones" {
  type        = list(string)
  default     = []
  description = "AZs for the subnets, parallel to subnet_cidrs. Empty = the first N available AZs in the provider's region."

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == length(var.subnet_cidrs)
    error_message = "availability_zones must be empty or the same length as subnet_cidrs."
  }
}

variable "route_table_id" {
  type        = string
  description = <<-EOT
    Existing route table to associate the dedicated subnets with. It MUST provide:
      - a default route 0.0.0.0/0 -> an Internet Gateway (public postures A / A-VPN)
        or a NAT gateway (private postures B / C). Devboxes need outbound HTTPS
        (AWS SSM, the Starfolk coordinator, the tunnel lighthouse, GitHub, package
        mirrors) or they never finish provisioning.
      - routes to any peered-VPC / Transit-Gateway / on-prem resources the agent
        must reach. The intra-VPC (local) route is automatic; cross-network routes
        are not -- pick a table that already carries them.
    We only associate the subnets with this table; we never modify the table itself.
  EOT
}

variable "assign_public_ip" {
  type        = bool
  default     = true
  description = "Auto-assign a public IP on launch. true for postures A / A-VPN; false for private postures B / C."
}

variable "ssh_ingress_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDRs allowed inbound on TCP 22 (SSH) and 443 (web-PTY) — the human/browser
    facing ports. (Port 7681, the coordinator control surface, is separate — see
    coordinator_ingress_cidrs.) Set per access posture:
      A     (public, open)          -> ["0.0.0.0/0"]
      A-VPN (public, behind VPN)    -> ["<your-vpn-egress-cidr>"]
      B     (private, VPN)          -> ["<vpc-or-vpn-cidr>"]
      C     (private, overlay)      -> []   (overlay rides nebula0; no 22/443 needed)
  EOT
}

variable "coordinator_ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = <<-EOT
    CIDR(s) allowed inbound on TCP 7681 (DEVBOX_PORT). This is the box's full
    control surface: the Starfolk coordinator's terminal proxy dials
    ws://<box-ip>:7681 directly, and ONLY the coordinator connects here (the
    browser talks to the coordinator, not the box). Set this to the coordinator's
    egress range for the stage that manages these boxes — it differs per
    deployment (prod coordinator vs dev vs a local devbox). Defaults to 0.0.0.0/0
    so the web terminal works out of the box; TIGHTEN it to the coordinator egress
    for a real customer (Starfolk provides the range).
  EOT
}

variable "enable_nebula_ingress" {
  type        = bool
  default     = true
  description = "Open UDP 51820 (Nebula overlay peer traffic) from 0.0.0.0/0. CA-authenticated; unauthenticated UDP is silently dropped. Harmless no-op for postures that don't use the overlay."
}

variable "sfk_principal_arn" {
  type        = string
  default     = "arn:aws:iam::450410490644:role/sfk-coordinator-remote-prod"
  description = "The Starfolk coordinator principal that is allowed to assume the control role. Starfolk provides this."
}

variable "external_id" {
  type        = string
  default     = ""
  description = "External ID for the control-role trust (confused-deputy guard). Empty = a random one is generated and surfaced in the `external_id` output; send it back to Starfolk."
}

variable "stage" {
  type        = string
  default     = "prod"
  description = "The coordinator stage that will manage these boxes. Scopes the destructive-EC2 and SendCommand IAM conditions to the sfk:<stage>:managed tag."
}

variable "name_prefix" {
  type        = string
  default     = "sfk-devbox"
  description = "Name prefix for created resources (role/profile/SG/subnets)."
}

variable "ami_kms_key_arns" {
  type        = list(string)
  default     = ["arn:aws:kms:*:450410490644:key/*"]
  description = <<-EOT
    KMS key ARN(s) the control role may use to launch a devbox AMI whose EBS
    snapshot is encrypted with a Starfolk-owned customer-managed key. The
    coordinator assumes the control role, so RunInstances must Decrypt the shared
    snapshot and let EC2 create per-volume grants. Defaults to Starfolk's
    AMI-encryption account; Starfolk can give you the exact key ARN to narrow it.
    Set to [] if the AMI you launch is unencrypted (no KMS grant emitted).
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged onto every resource this module creates."
}
