# Starfolk BYOC — provisions, in your AWS account, everything Starfolk needs to
# launch and manage devboxes there, expressed against an EXISTING VPC you supply.

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Bring-your-own subnets: when subnet_ids is set the module attaches to these
# existing subnets instead of creating new ones. We read them to (a) derive the
# access_mode hint from their real auto-assign-public-IP setting and (b) build
# their ARNs for the RunInstances least-privilege pin. No-op when subnet_ids is
# empty (the module creates subnets from subnet_cidrs instead).
data "aws_subnet" "byo" {
  for_each = toset(var.subnet_ids)
  id       = each.value

  lifecycle {
    postcondition {
      # Catch a wrong-VPC subnet id at plan time with a clear message, rather
      # than an opaque RunInstances/SG-mismatch failure at launch. The SG (and
      # any created resources) live in var.vpc_id, so every BYO subnet must too.
      condition     = self.vpc_id == var.vpc_id
      error_message = "subnet_ids entry ${self.id} is in VPC ${self.vpc_id}, not vpc_id (${var.vpc_id})."
    }
  }
}

# Optional source-SG ingress: the security groups whose members may reach the
# boxes on the configured port range. We read each one to fail at plan time on a
# wrong-VPC id — AWS resolves security group references only within a VPC (the
# devbox SG lives in var.vpc_id), and an apply-time rejection here is opaque.
# No-op when ingress_source_security_group_ids is empty (the default).
data "aws_security_group" "ingress_source" {
  for_each = toset(var.ingress_source_security_group_ids)
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id
      error_message = "ingress_source_security_group_ids entry ${self.id} is in VPC ${self.vpc_id}, not vpc_id (${var.vpc_id})."
    }
  }
}

resource "random_uuid" "external_id" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  external_id = var.external_id != "" ? var.external_id : "sfk-${random_uuid.external_id.result}"
  azs         = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, length(var.subnet_cidrs))
  common_tags = merge({ "sfk:byoc" = "true" }, var.tags)

  # Shared devbox AMIs are encrypted with a different Starfolk-owned CMK in
  # each AWS region. Keep this map closed rather than accepting an arbitrary
  # key ARN: the control role gets decrypt/grant access only to the exact key
  # used by AMIs in the explicitly selected, supported region.
  ami_kms_key_arn_by_region = {
    us-east-2 = "arn:aws:kms:us-east-2:450410490644:key/4bcb6251-1960-46ca-859e-3a5f24757caa"
    us-west-2 = "arn:aws:kms:us-west-2:450410490644:key/e661422c-3f6e-426f-a8d3-434f64deab8a"
  }
  ami_kms_key_arns = var.ami_kms_key_arns == null ? [local.ami_kms_key_arn_by_region[var.region]] : var.ami_kms_key_arns

  # The instance profile the coordinator launches devboxes with, and the role
  # inside it that iam:PassRole is pinned to. Either the module creates them
  # (default) or the customer brings their own (create_instance_profile = false)
  # — e.g. a role carrying a DenyAnyAssumeRole guardrail they own end-to-end.
  instance_profile_name = var.create_instance_profile ? aws_iam_instance_profile.devbox[0].name : var.instance_profile_name
  instance_role_arn     = var.create_instance_profile ? aws_iam_role.devbox[0].arn : var.instance_role_arn

  # Subnets the boxes launch into: the ones we create (subnet_cidrs), or the
  # existing ones you pass (subnet_ids). Exactly one is set (see the variable
  # validations). ``subnet_arns`` feeds the RunInstances least-privilege pin —
  # for BYO subnets we build the ARNs from the ids (no create to read .arn off).
  create_subnets       = length(var.subnet_ids) == 0
  subnet_ids_effective = local.create_subnets ? aws_subnet.this[*].id : var.subnet_ids
  subnet_arns = local.create_subnets ? aws_subnet.this[*].arn : [
    for id in var.subnet_ids : "arn:aws:ec2:${var.region}:${local.account_id}:subnet/${id}"
  ]

  # access_mode hint emitted in the hand-back (maps to cloud_accounts.access_mode).
  # Created subnets → declared via assign_public_ip. BYO subnets → read from the
  # subnets' *actual* map_public_ip_on_launch, so a private subnet correctly
  # yields "vpn_private" with no extra flag for the customer to remember.
  boxes_get_public_ip = local.create_subnets ? var.assign_public_ip : anytrue([
    for s in data.aws_subnet.byo : s.map_public_ip_on_launch
  ])
  access_mode = local.boxes_get_public_ip ? "public" : "vpn_private"

  # ── Least-privilege pinning ──
  # RunInstances is pinned to the exact subnet + SG we create; PassRole to the
  # devbox instance-profile role; SendCommand tag-scoped to SFK-managed boxes.
  run_instances_resources = concat(
    local.subnet_arns,
    [
      aws_security_group.this.arn,
      "arn:aws:ec2:*:*:image/*",
      "arn:aws:ec2:*:*:network-interface/*",
      "arn:aws:ec2:*:*:volume/*",
      "arn:aws:ec2:*:*:key-pair/*",
    ],
  )

  # Human/browser-facing ingress from each allowed CIDR (posture-dependent):
  #   22   SSH (always configured for every ssh_ingress_cidrs entry)
  #   443  public web-PTY listener (ticket-gated wss; opt-in)
  # DEVBOX_PORT 7681 is deliberately NOT here — it's the full control surface and
  # only the *coordinator* connects to it (ws://<ip>:7681), so it gets its own
  # coordinator-scoped rule below rather than being opened to the human CIDRs.
  ssh_ports = merge(
    { ssh = 22 },
    var.enable_web_sessions ? { webpty = 443 } : {},
  )
  ssh_rules = {
    for pair in setproduct(keys(local.ssh_ports), var.ssh_ingress_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = local.ssh_ports[pair[0]], cidr = pair[1] }
  }
  # 7681 opened only to the Starfolk coordinator's egress range(s). The coordinator
  # proxies the browser terminal to the box here; the browser never hits it.
  coordinator_rules = { for cidr in var.coordinator_ingress_cidrs : cidr => cidr }

  # Optional source-SG ingress: one rule per (protocol, source SG) over the
  # configured port range. TCP *and* UDP by default — the range is the control
  # here, and an agent's service is as likely to be UDP (QUIC, a metrics
  # receiver) as TCP; ingress_source_protocols narrows it. Empty by default.
  source_sg_rules = {
    for pair in setproduct(var.ingress_source_protocols, var.ingress_source_security_group_ids) :
    "${pair[0]}-${pair[1]}" => { protocol = pair[0], source_sg = pair[1] }
  }
}

# ── Dedicated subnets in the existing VPC (one per AZ) ───────────────────────
resource "aws_subnet" "this" {
  count                   = length(var.subnet_cidrs)
  vpc_id                  = var.vpc_id
  cidr_block              = var.subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = var.assign_public_ip
  tags                    = merge(local.common_tags, { Name = "${var.name_prefix}-${count.index}" })
}

# Associate with the customer's existing route table (public/IGW or NAT). We
# only associate — we never create or mutate the customer's routing.
resource "aws_route_table_association" "this" {
  count          = length(aws_subnet.this)
  subnet_id      = aws_subnet.this[count.index].id
  route_table_id = var.route_table_id
}

# ── Dedicated security group ─────────────────────────────────────────────────
resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-sg"
  description = "Starfolk BYOC devboxes"
  vpc_id      = var.vpc_id
  tags        = merge(local.common_tags, { Name = "${var.name_prefix}-sg" })

  lifecycle {
    postcondition {
      condition     = split(":", self.arn)[3] == var.region
      error_message = "The module region (${var.region}) must match the AWS provider region (${split(":", self.arn)[3]})."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "nebula" {
  count             = var.enable_nebula_ingress ? 1 : 0
  security_group_id = aws_security_group.this.id
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Nebula tunnel listen port (CA-authenticated)"
}

resource "aws_vpc_security_group_ingress_rule" "ssh_webpty" {
  for_each          = local.ssh_rules
  security_group_id = aws_security_group.this.id
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  description       = "TCP ${each.value.port} (SSH/web-PTY) from ${each.value.cidr}"
}

# DEVBOX_PORT (7681): the coordinator's terminal proxy dials ws://<ip>:7681
# directly, so it must be reachable from the coordinator's egress — and ONLY
# from there (it's the full box control surface). Scoped to coordinator_ingress_cidrs,
# which differs per coordinator deployment (prod vs dev vs a local devbox).
# Gated on enable_coordinator_access (default false): when off, 7681 is never opened
# and boxes are reached over SSH / Nebula instead (SSM control is unaffected).
resource "aws_vpc_security_group_ingress_rule" "coordinator" {
  for_each          = var.enable_coordinator_access ? local.coordinator_rules : {}
  security_group_id = aws_security_group.this.id
  ip_protocol       = "tcp"
  from_port         = 7681
  to_port           = 7681
  cidr_ipv4         = each.value
  description       = "TCP 7681 (DEVBOX_PORT) from Starfolk coordinator ${each.value}"
}

# Optional: let a workload of yours reach a service an agent runs on the box (a
# dev server, a debugger, an internal test harness). Scoped by SOURCE SG rather
# than CIDR, so the rule follows the workload's instances as they scale. The port
# range defaults to 1024-65535 — the unprivileged range — which is why this can't
# accidentally widen 22 / 443 / 7681: those sit below 1024 and keep their own
# CIDR-scoped rules above. That range, not the protocol, is what bounds this, so
# both TCP and UDP are opened by default (see ingress_source_protocols). Created
# only for the SGs passed in; none by default.
resource "aws_vpc_security_group_ingress_rule" "source_security_group" {
  for_each = local.source_sg_rules

  security_group_id = aws_security_group.this.id
  ip_protocol       = each.value.protocol
  from_port         = var.ingress_source_from_port
  to_port           = var.ingress_source_to_port
  # Read through the data source, so its wrong-VPC postcondition gates the rule.
  referenced_security_group_id = data.aws_security_group.ingress_source[each.value.source_sg].id
  description                  = "${upper(each.value.protocol)} ${var.ingress_source_from_port}-${var.ingress_source_to_port} from security group ${each.value.source_sg}"

  lifecycle {
    precondition {
      # The devbox SG's own id would make this a self-rule, letting every box
      # open connections to every other box on the range — never what's wanted
      # here, and it's the one id a customer might paste back from an earlier
      # hand-back. Pass the SOURCE workload's SG instead.
      condition     = each.value.source_sg != aws_security_group.this.id
      error_message = "ingress_source_security_group_ids must not contain the module's own devbox security group (${aws_security_group.this.id}) — that would be a box-to-box self-rule. Pass the source workload's security group."
    }
  }
}

# Terraform-created SGs have no default egress; add an explicit allow-all.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Allow all egress"
}

# ── Optional co-tenant isolation (network ACL) ───────────────────────────────
# SGs protect the boxes on inbound but are allow-only, so they can't stop a box
# from reaching a neighbor in the same VPC. A NACL is the one control that
# supports DENY, so isolate_from_cidrs is enforced here: deny the listed CIDRs
# (both directions, low rule numbers → evaluated first), allow everything else.
# Created only when isolate_from_cidrs is non-empty; otherwise the subnets keep
# the VPC default ACL (allow-all). Do NOT extend this to the whole VPC CIDR —
# SSM interface endpoints and the VPC DNS resolver live in it (see the var doc).
locals {
  isolation_enabled = length(var.isolate_from_cidrs) > 0
  # Stable per-CIDR rule numbers starting at 100 (well below the allow-all baseline).
  isolation_rules = { for i, cidr in var.isolate_from_cidrs : tostring(i) => { num = 100 + i, cidr = cidr } }
}

resource "aws_network_acl" "isolation" {
  count  = local.isolation_enabled ? 1 : 0
  vpc_id = var.vpc_id
  # Attach to whichever subnets the boxes use — created or bring-your-own. For
  # BYO subnets this REPLACES the subnet's current ACL, so those subnets must be
  # dedicated to SFK boxes (see the isolate_from_cidrs var doc).
  subnet_ids = local.subnet_ids_effective
  tags       = merge(local.common_tags, { Name = "${var.name_prefix}-isolation" })
}

resource "aws_network_acl_rule" "deny_ingress" {
  for_each       = local.isolation_enabled ? local.isolation_rules : {}
  network_acl_id = aws_network_acl.isolation[0].id
  rule_number    = each.value.num
  egress         = false
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = each.value.cidr
}

resource "aws_network_acl_rule" "deny_egress" {
  for_each       = local.isolation_enabled ? local.isolation_rules : {}
  network_acl_id = aws_network_acl.isolation[0].id
  rule_number    = each.value.num
  egress         = true
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = each.value.cidr
}

# Allow-all baseline (evaluated after the denies). Both directions, protocol -1
# — NACLs are stateless, so this single rule per direction carries return traffic
# for everything not explicitly denied above.
resource "aws_network_acl_rule" "allow_ingress" {
  count          = local.isolation_enabled ? 1 : 0
  network_acl_id = aws_network_acl.isolation[0].id
  rule_number    = 32000
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

resource "aws_network_acl_rule" "allow_egress" {
  count          = local.isolation_enabled ? 1 : 0
  network_acl_id = aws_network_acl.isolation[0].id
  rule_number    = 32000
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# ── Devbox instance profile (SSM agent registration) ────────────────────────
# Created only when create_instance_profile = true (the default). Set it false
# to bring your own profile/role (instance_profile_name + instance_role_arn) —
# then none of these three resources exist and the coordinator launches with,
# and iam:PassRole is pinned to, exactly what you passed.
resource "aws_iam_role" "devbox" {
  count = var.create_instance_profile ? 1 : 0
  name  = var.name_prefix
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count      = var.create_instance_profile ? 1 : 0
  role       = aws_iam_role.devbox[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Opt-in DenyAnyAssumeRole guardrail on the module-created role: the devbox
# never needs to assume another role, so denying sts:AssumeRole caps blast
# radius if the box is compromised. Only attachable when the module owns the
# role — bring-your-own carries whatever guardrails you author yourself.
resource "aws_iam_role_policy" "devbox_deny_assume_role" {
  count = var.create_instance_profile && var.deny_instance_role_assume_role ? 1 : 0
  name  = "sfk-deny-assume-role"
  role  = aws_iam_role.devbox[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyAnyAssumeRole"
      Effect   = "Deny"
      Action   = "sts:AssumeRole"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "devbox" {
  count = var.create_instance_profile ? 1 : 0
  name  = var.name_prefix
  role  = aws_iam_role.devbox[0].name
}

# ── Cross-account control role (assumed by the coordinator) ──────────────────
resource "aws_iam_role" "control" {
  name                 = "${var.name_prefix}-control"
  description          = "Assumed by the Starfolk coordinator to launch/manage BYOC devboxes"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.sfk_principal_arn }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = local.external_id } }
    }]
  })
  tags = local.common_tags
}

locals {
  # KMS lets the control role launch a CMK-encrypted devbox AMI: the coordinator
  # assumes this role, so RunInstances must Decrypt the shared snapshot and let
  # EC2 make its own per-volume grants. Split use vs. CreateGrant so the
  # AWS-resource condition gates only grant creation (mirrors setup-aws.sh).
  control_kms_statements = [
    for statement in [
      {
        Sid      = "SFKDevboxAMIKMSUse"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = local.ami_kms_key_arns
      },
      {
        Sid       = "SFKDevboxAMIKMSGrant"
        Effect    = "Allow"
        Action    = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
        Resource  = local.ami_kms_key_arns
        Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
      },
    ] : statement
    if length(local.ami_kms_key_arns) > 0
  ]

  # Optional customer-reviewed grants. Keep the volume reads behind the same
  # switch as ModifyVolume: although read-only, they exist only to feed that
  # mutation and a default-off upgrade must add none of the grant's actions.
  control_volume_statements = [
    for statement in [
      {
        Sid      = "EC2DescribeVolumes"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVolumes", "ec2:DescribeVolumesModifications"]
        Resource = "*"
      },
      {
        Sid       = "EC2ModifyTaggedVolumes"
        Effect    = "Allow"
        Action    = ["ec2:ModifyVolume"]
        Resource  = "arn:aws:ec2:*:*:volume/*"
        Condition = { StringEquals = { ("aws:ResourceTag/sfk:${var.stage}:managed") = "true" } }
      },
    ] : statement
    if var.enable_ec2_modify_tagged_volumes
  ]

  control_metric_statements = [
    for statement in [
      {
        # GetMetricData has no resource-level condition, so "*" is the only
        # expressible resource. The action is read-only.
        Sid      = "CloudWatchReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
    ] : statement
    if var.enable_cloudwatch_read_metrics
  ]
}

resource "aws_iam_role_policy" "control" {
  name = "sfk-control"
  role = aws_iam_role.control.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances", "ec2:DescribeInstanceAttribute", "ec2:DescribeInstanceTypes",
          "ec2:DescribeTags", "ec2:DescribeImages", "ec2:DescribeAddresses",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeKeyPairs",
        ]
        Resource = "*"
      },
      {
        Sid       = "EC2RunInstances"
        Effect    = "Allow"
        Action    = "ec2:RunInstances"
        Resource  = "arn:aws:ec2:*:*:instance/*"
        Condition = { "ForAnyValue:StringLike" = { "aws:TagKeys" = "sfk:*:managed" } }
      },
      {
        Sid      = "EC2RunInstancesResources"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = local.run_instances_resources
      },
      {
        Sid       = "EC2CreateTags"
        Effect    = "Allow"
        Action    = "ec2:CreateTags"
        Resource  = ["arn:aws:ec2:*:*:instance/*", "arn:aws:ec2:*:*:volume/*"]
        Condition = { StringEquals = { "ec2:CreateAction" = "RunInstances" } }
      },
      {
        Sid    = "EC2ManageTaggedInstances"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances", "ec2:StopInstances", "ec2:StartInstances",
          "ec2:CreateTags", "ec2:DeleteTags", "ec2:ModifyInstanceAttribute",
        ]
        Resource  = "arn:aws:ec2:*:*:instance/*"
        Condition = { StringEquals = { ("aws:ResourceTag/sfk:${var.stage}:managed") = "true" } }
      },
      {
        Sid       = "PassRole"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = local.instance_role_arn
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      },
      {
        Sid      = "CloudWatchAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms"]
        Resource = ["arn:aws:cloudwatch:*:*:alarm:sfk-*-egress-*", "arn:aws:cloudwatch:*:*:alarm:EC2-PublicIPv4-Created"]
      },
      {
        Sid       = "SSMSendCommandInstances"
        Effect    = "Allow"
        Action    = ["ssm:SendCommand"]
        Resource  = "arn:aws:ec2:*:*:instance/*"
        Condition = { StringEquals = { ("ssm:resourceTag/sfk:${var.stage}:managed") = "true" } }
      },
      {
        Sid      = "SSMSendCommandDocument"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:*::document/AWS-RunShellScript"
      },
      {
        Sid      = "SSMGetInvocation"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation"]
        Resource = "*"
      },
      {
        Sid      = "SSMParameterBootstrap"
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:DeleteParameter"]
        Resource = "arn:aws:ssm:*:*:parameter/sfk/*/nebula-bootstrap/*"
      },
      ],
      local.control_volume_statements,
      local.control_metric_statements,
      local.control_kms_statements,
    )
  })
}
