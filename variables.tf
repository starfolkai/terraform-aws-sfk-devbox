variable "vpc_id" {
  type        = string
  description = "Existing (shared) VPC to place the dedicated SFK devbox subnets in. This module never creates a VPC — it expresses its requirements against yours."
}

variable "region" {
  type        = string
  default     = "us-east-2"
  description = "AWS region where Starfolk devboxes will run. Must match the region configured on the AWS provider passed to this module. Defaults to us-east-2 for compatibility with module versions before 1.1.1."

  validation {
    condition     = contains(["us-east-2", "us-west-2"], var.region)
    error_message = "Unsupported region. Starfolk BYOC currently supports only us-east-2 and us-west-2."
  }
}

variable "subnet_cidrs" {
  type        = list(string)
  default     = []
  description = "One CIDR per AZ for dedicated SFK devbox subnets the module CREATES, chosen from free space in your VPC (one subnet per entry). Leave empty and set subnet_ids instead to attach boxes to EXISTING subnets. Set exactly one of subnet_cidrs / subnet_ids."

  validation {
    # Exactly one of subnet_cidrs (create) or subnet_ids (bring-your-own).
    condition     = (length(var.subnet_cidrs) > 0) != (length(var.subnet_ids) > 0)
    error_message = "Set exactly one of subnet_cidrs (module creates subnets) or subnet_ids (attach to existing subnets you pass)."
  }
}

variable "subnet_ids" {
  type        = list(string)
  default     = []
  description = <<-EOT
    EXISTING subnet IDs to launch devboxes into, instead of the module creating
    new ones. Set this (and leave subnet_cidrs empty) when your VPC has no free
    CIDR space to carve dedicated subnets, or you want boxes in your existing
    private subnets. The module then attaches the SG to these subnets and pins
    RunInstances to them; it does NOT create subnets, does NOT associate a route
    table (your subnets already have routing), and does NOT set map_public_ip
    (your subnets' own setting governs). For a private subnet (no public IP) the
    hand-back's access_mode is emitted as "vpn_private" automatically — the
    coordinator then addresses boxes by their private IP over your VPN.
    NOTE: if you also set isolate_from_cidrs, the module attaches its NACL to
    these subnets, REPLACING their current ACL — so the subnets you pass must be
    DEDICATED to SFK boxes (no other workloads), or the isolation affects them too.
  EOT
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
  default     = ""
  description = <<-EOT
    Existing route table to associate the module-CREATED subnets with (required
    only when using subnet_cidrs; ignored with subnet_ids, since your existing
    subnets already have routing). It MUST provide:
      - a default route 0.0.0.0/0 -> an Internet Gateway (public postures A / A-VPN)
        or a NAT gateway (private postures B / C). Devboxes need outbound HTTPS
        (AWS SSM, the Starfolk coordinator, the tunnel lighthouse, GitHub, package
        mirrors) or they never finish provisioning.
      - routes to any peered-VPC / Transit-Gateway / on-prem resources the agent
        must reach. The intra-VPC (local) route is automatic; cross-network routes
        are not -- pick a table that already carries them.
    We only associate the subnets with this table; we never modify the table itself.
  EOT

  validation {
    # Required when the module creates subnets; irrelevant for bring-your-own.
    condition     = length(var.subnet_ids) > 0 || var.route_table_id != ""
    error_message = "route_table_id is required when the module creates subnets (subnet_cidrs)."
  }
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
    CIDRs allowed inbound on TCP 22 (SSH) and, when enable_web_sessions is true,
    TCP 443 (web-PTY) — the human/browser-facing ports. (Port 7681, the
    coordinator control surface, is separate — see coordinator_ingress_cidrs.)
    Set per access posture:
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
    Open TCP 443 for browser-based terminal sessions. The ingress rules use the
    same ssh_ingress_cidrs as TCP 22. Defaults to false, so only SSH is opened
    for those CIDRs. This setting does not expose the coordinator control port;
    use enable_coordinator_access to open TCP 7681 separately.
  EOT
}

variable "enable_coordinator_access" {
  type        = bool
  default     = false
  description = <<-EOT
    Open TCP 7681 (DEVBOX_PORT) for direct access from the Starfolk coordinator.
    The coordinator's terminal proxy dials ws://<box-ip>:7681 directly, so the
    ingress rules use coordinator_ingress_cidrs rather than the human-facing
    ssh_ingress_cidrs. Defaults to false; coordinator management over SSM is
    unaffected when this port is closed.
  EOT
}

variable "coordinator_ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = <<-EOT
    CIDR(s) allowed inbound on TCP 7681 (DEVBOX_PORT) — applies ONLY when
    enable_coordinator_access = true (otherwise 7681 is never opened, whatever
    this is set to). This is the box's full control surface: the Starfolk
    coordinator's terminal proxy dials ws://<box-ip>:7681 directly, and ONLY the
    coordinator connects here (the browser talks to the coordinator, not the
    box). Set it to the coordinator's egress range for the stage that manages
    these boxes — it differs per deployment (prod coordinator vs dev vs a local
    devbox). Starfolk provides the range; TIGHTEN it from the 0.0.0.0/0 default
    for a real customer.
  EOT
}

variable "ingress_source_security_group_ids" {
  type        = list(string)
  default     = []
  description = <<-EOT
    OPTIONAL. Security group ID(s) in vpc_id whose members are allowed inbound to
    the devboxes on ingress_source_from_port-ingress_source_to_port (default
    1024-65535), for each protocol in ingress_source_protocols (default TCP and
    UDP). Use this when a workload of yours must reach a service an agent runs on
    a box (a dev server, a debugger, an internal test harness) — an SG-to-SG
    reference tracks the workload's instances as they scale, so you never chase
    their IPs.
    Empty (default) is a no-op: no such rule exists and this input changes
    nothing. Setting it does NOT widen any other port — 22 / 443 / 7681 / Nebula
    keep their own knobs and CIDRs.
    Each SG must live in vpc_id (checked at plan time), since the devbox SG does
    and AWS only resolves same-VPC SG references. Pass the SG of the *source*
    workload, not the devbox SG — a self-reference would let any box open
    connections to any other box.
    Note the direction: this is inbound to the boxes only. It does not let a box
    reach your workload — that's the workload's own SG's job (allow the
    security_group_id from the hand-back). And an isolate_from_cidrs deny still
    wins, because the NACL is evaluated before the SG.
  EOT

  validation {
    condition = alltrue([
      for id in var.ingress_source_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", id))
    ])
    error_message = "ingress_source_security_group_ids entries must be security group IDs (sg-...)."
  }
}

variable "ingress_source_protocols" {
  type        = list(string)
  default     = ["tcp", "udp"]
  description = <<-EOT
    IP protocols the ingress_source_security_group_ids range is opened for. One
    rule is created per (protocol, source SG). Defaults to both TCP and UDP: a
    port range is a port range, and an agent's service may well be UDP (a QUIC
    dev server, a metrics receiver, a game server), so restricting to TCP would
    just be an arbitrary gap. Narrow it to ["tcp"] (or ["udp"]) when you know
    which one you need — that's the only reason to set this.
    Only "tcp" and "udp" are accepted: they are the protocols a port RANGE is
    meaningful for. ICMP has no ports, and the all-protocols wildcard ("-1")
    cannot carry a port range at all — for either of those, tell us what you're
    trying to reach and we'll shape a rule for it.
    Ignored when ingress_source_security_group_ids is empty.
  EOT

  validation {
    condition     = length(var.ingress_source_protocols) > 0
    error_message = "ingress_source_protocols must not be empty — omit it for the default [\"tcp\", \"udp\"], or leave ingress_source_security_group_ids empty to add no rules at all."
  }

  validation {
    condition = alltrue([
      for protocol in var.ingress_source_protocols : contains(["tcp", "udp"], protocol)
    ])
    error_message = "ingress_source_protocols entries must be \"tcp\" or \"udp\" (lowercase) — the protocols a port range applies to."
  }

  validation {
    condition     = length(distinct(var.ingress_source_protocols)) == length(var.ingress_source_protocols)
    error_message = "ingress_source_protocols must not repeat a protocol."
  }
}

variable "ingress_source_from_port" {
  type        = number
  default     = 1024
  description = <<-EOT
    First port of the range opened to ingress_source_security_group_ids, for
    every protocol in ingress_source_protocols. Defaults to 1024 — the
    unprivileged range, where an agent's dev servers and test harnesses listen —
    so the well-known ports below it (including 22 and 443) are NOT reachable
    from the source SG unless you lower this deliberately.
    Ignored when ingress_source_security_group_ids is empty.
  EOT

  validation {
    condition     = var.ingress_source_from_port >= 0 && var.ingress_source_from_port <= 65535
    error_message = "ingress_source_from_port must be between 0 and 65535."
  }
}

variable "ingress_source_to_port" {
  type        = number
  default     = 65535
  description = <<-EOT
    Last port of the range opened to ingress_source_security_group_ids, for every
    protocol in ingress_source_protocols. Defaults to 65535 (MAX), so the default
    range is the whole unprivileged space, 1024-65535.
    Ignored when ingress_source_security_group_ids is empty.
  EOT

  validation {
    condition     = var.ingress_source_to_port >= 0 && var.ingress_source_to_port <= 65535
    error_message = "ingress_source_to_port must be between 0 and 65535."
  }

  validation {
    condition     = var.ingress_source_to_port >= var.ingress_source_from_port
    error_message = "ingress_source_to_port must be greater than or equal to ingress_source_from_port."
  }
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
  default     = null
  nullable    = true
  description = <<-EOT
    Deprecated compatibility override for the KMS key ARN(s) the control role
    may use to launch encrypted devbox AMIs. Omit this in 1.1.1 and later: the
    module selects the correct Starfolk-owned key from `region`. If retained by
    an existing caller, it must be empty (for an unencrypted AMI) or exactly the
    supported key for `region`.
  EOT

  validation {
    condition = var.ami_kms_key_arns == null ? true : (
      length(var.ami_kms_key_arns) == 0 ? true : (
        length(var.ami_kms_key_arns) == 1 &&
        var.ami_kms_key_arns[0] == (
          var.region == "us-west-2" ?
          "arn:aws:kms:us-west-2:450410490644:key/e661422c-3f6e-426f-a8d3-434f64deab8a" :
          "arn:aws:kms:us-east-2:450410490644:key/4bcb6251-1960-46ca-859e-3a5f24757caa"
        )
      )
    )
    error_message = "ami_kms_key_arns must be omitted, empty, or exactly the Starfolk shared-AMI KMS key for region."
  }
}

variable "session_archive_bucket" {
  type        = string
  default     = ""
  description = <<-EOT
    OPTIONAL. Name of an S3 bucket **in your account** where the transcript of
    each terminated agent session is archived. This module does not create it —
    it is your bucket, with your encryption, retention and key policy — it only
    grants the Starfolk control role `s3:PutObject` on
    `<bucket>/<session_archive_prefix>*`, and deliberately NOT `s3:GetObject`,
    `s3:ListBucket` or any delete. Starfolk can deposit your sessions' logs and
    cannot read them back — not even the ones it wrote.

    What lands here: the agent's own JSONL log for the session — prompts, model
    output, tool calls, command output, and contents of files the agent read —
    gzipped, one object per session under
    `<prefix>/<stage>/session-logs/workspace_id=…/session_id=…/terminated=…/rev=N.jsonl.gz`.

    Leave empty and no S3 grant is created: on terminate Starfolk then **deletes**
    the session's log content from its own database with no copy kept anywhere. It
    is never written to a Starfolk-owned bucket.

    Pass the value back to Starfolk with the rest of the hand-back (it is in
    `terraform output -json`) — the grant existing in IAM is not enough on its
    own; the archive only starts once the bucket is registered against your cloud
    account.
  EOT

  validation {
    # S3 bucket naming, loosely: 3-63 chars, lowercase alphanumerics, dots and
    # hyphens. Catches an ARN or an s3:// URL pasted in by mistake, which would
    # otherwise produce a policy that silently matches nothing — a grant that
    # looks present and denies every write.
    condition     = var.session_archive_bucket == "" || can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.session_archive_bucket))
    error_message = "session_archive_bucket must be a bare S3 bucket name (no arn:, no s3:// prefix, no trailing slash)."
  }
}

variable "session_archive_prefix" {
  type        = string
  default     = ""
  description = <<-EOT
    OPTIONAL key preamble inside `session_archive_bucket` — set it to share a
    bucket with other data, and the grant narrows to that prefix. Leading and
    trailing slashes are ignored. Empty = keys start at the top of the bucket and
    the grant covers the whole bucket's objects.
  EOT
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags merged onto every resource this module creates."
}
