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

variable "enable_web_sessions" {
  type        = bool
  default     = false
  description = <<-EOT
    Open TCP 7681 (DEVBOX_PORT) so the Starfolk coordinator can serve the
    browser-based terminal ("web sessions"). The coordinator's terminal proxy
    dials ws://<box-ip>:7681 directly, so this port must be reachable FROM the
    coordinator for the web terminal to work. Defaults to false — 7681 stays
    closed and users reach boxes over SSH (22) or the Nebula overlay instead;
    the coordinator still manages boxes over SSM regardless. Set true (and scope
    coordinator_ingress_cidrs to the coordinator's egress) only for a public
    posture where the coordinator can route to the box's IP. A no-public-IP /
    VPN posture (assign_public_ip = false) can't serve web sessions — the
    coordinator isn't on your VPN — so leave this false there.
  EOT
}

variable "coordinator_ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = <<-EOT
    CIDR(s) allowed inbound on TCP 7681 (DEVBOX_PORT) — applies ONLY when
    enable_web_sessions = true (otherwise 7681 is never opened, whatever this is
    set to). This is the box's full control surface: the Starfolk coordinator's
    terminal proxy dials ws://<box-ip>:7681 directly, and ONLY the coordinator
    connects here (the browser talks to the coordinator, not the box). Set it to
    the coordinator's egress range for the stage that manages these boxes — it
    differs per deployment (prod coordinator vs dev vs a local devbox). Starfolk
    provides the range; TIGHTEN it from the 0.0.0.0/0 default for a real customer.
  EOT
}

variable "isolate_from_cidrs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    CIDR(s) of co-tenant workloads in the SAME VPC to fully isolate the devboxes
    from, in BOTH directions. When non-empty, the module attaches a network ACL
    to the dedicated devbox subnets that DENYs these CIDRs (inbound + outbound)
    and allows everything else — so boxes keep full internet/DNS/SSM but cannot
    reach, or be reached by, the listed workloads. Empty (default) leaves the
    subnets on the VPC's default ACL (allow-all), relying on security groups
    alone. We use a NACL rather than an SG egress rule because SGs are allow-only
    and can't express a deny; NACLs are stateless, so the module's allow-all
    baseline covers return traffic. Prefer a whole subnet/summary CIDR per
    neighbor. (Do NOT try to block the whole VPC CIDR this way — the boxes'
    in-VPC dependencies, SSM interface endpoints and the VPC DNS resolver, live
    in the VPC CIDR and would break.)
  EOT

  validation {
    condition     = length(var.isolate_from_cidrs) <= 18
    error_message = "isolate_from_cidrs supports up to 18 CIDRs (AWS network ACL rule quota). Summarize into fewer CIDRs, or raise the account NACL rule quota and adjust."
  }
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

variable "create_instance_profile" {
  type        = bool
  default     = true
  description = <<-EOT
    Whether this module creates the `sfk-devbox` IAM role + instance profile the
    coordinator launches devboxes with. Leave true to let Starfolk own it. Set
    false to BRING YOUR OWN — e.g. a role you author with a DenyAnyAssumeRole
    guardrail — then you MUST also set `instance_profile_name` and
    `instance_role_arn`. When false the module creates neither the role nor the
    profile, and the control role's `iam:PassRole` is pinned to exactly your
    `instance_role_arn`.
  EOT
}

variable "instance_profile_name" {
  type        = string
  default     = ""
  description = <<-EOT
    Bring-your-own instance profile NAME to launch devboxes with. Required when
    `create_instance_profile = false`; ignored otherwise. Your profile's role
    MUST carry `AmazonSSMManagedInstanceCore` (or equivalent SSM permissions) or
    the box's SSM agent never registers and it can't be managed.
  EOT

  validation {
    condition     = var.create_instance_profile || var.instance_profile_name != ""
    error_message = "instance_profile_name is required when create_instance_profile = false."
  }
}

variable "instance_role_arn" {
  type        = string
  default     = ""
  description = <<-EOT
    ARN of the IAM role inside your `instance_profile_name`. Required when
    `create_instance_profile = false` — the control role's `iam:PassRole` is
    pinned to exactly this ARN, so it must match the role the profile wraps.
  EOT

  validation {
    condition     = var.create_instance_profile || can(regex("^arn:aws:iam::[0-9]{12}:role/", var.instance_role_arn))
    error_message = "instance_role_arn must be a valid IAM role ARN when create_instance_profile = false."
  }
}

variable "deny_instance_role_assume_role" {
  type        = bool
  default     = false
  description = <<-EOT
    Attach a DenyAnyAssumeRole guardrail (Deny `sts:AssumeRole` on `*`) to the
    module-created devbox role. The devbox never needs to assume another role,
    so this caps blast radius if a box is compromised. Only applies when
    `create_instance_profile = true` (bring-your-own carries its own guardrails).
  EOT
}

variable "ami_kms_key_arns" {
  type        = list(string)
  default     = ["arn:aws:kms:us-east-2:450410490644:key/4bcb6251-1960-46ca-859e-3a5f24757caa"]
  description = <<-EOT
    KMS key ARN(s) the control role may use to launch a devbox AMI whose EBS
    snapshot is encrypted with a Starfolk-owned customer-managed key. The
    coordinator assumes the control role, so RunInstances must Decrypt the shared
    snapshot and let EC2 create per-volume grants. Defaults to the exact
    `alias/sfk-devbox-shared` CMK (us-east-2) — the single key every shared devbox
    AMI is encrypted under; the grant is scoped to just this key, not a wildcard.
    Override only if launching in another region (Starfolk supplies the
    region-matched key ARN) or with an unencrypted AMI (set to [] — no KMS grant).
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged onto every resource this module creates."
}
