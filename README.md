# Starfolk BYOC — Terraform module

Provisions, **in your AWS account**, everything Starfolk needs to launch and
manage devboxes there — expressed against your **existing VPC**, not a
greenfield one.

This repository is a plain Terraform **module**: it declares **no backend and no
provider** of its own. You bring your own state storage and provider/auth
settings and call this module from your infrastructure repo — see
[`examples/wrapper/`](examples/wrapper/). Review the source, pin a release tag,
and apply it with your own credentials; Starfolk never receives a key.

## What it creates

- **Subnets** — *either* dedicated ones the module creates (one per `subnet_cidrs` entry) in your `vpc_id`, associated with a route table you already have (`route_table_id`); *or* your **existing** subnets when you set `subnet_ids` (nothing is created). Either way we never create or mutate your VPC/IGW/NAT/routing. See [Subnets: create or bring your own](#subnets-create-or-bring-your-own).
- **Security group** with posture-appropriate ingress.
- **Instance profile** `sfk-devbox` (+ `AmazonSSMManagedInstanceCore`) so the box's SSM agent registers in your account. Optional — bring your own instead (see [Instance role: own it yourself](#instance-role-own-it-yourself)).
- **Control role** `sfk-devbox-control`, assumed by Starfolk (trust = SFK principal **+ external id**). Least-privilege: `iam:PassRole` pinned to the `sfk-devbox` role ARN, `ec2:RunInstances` pinned to the created subnet + SG ARNs, `ssm:SendCommand` tag-scoped to `sfk:<stage>:managed` instances, destructive EC2 actions tag-gated, and **no `sts:*` / no IAM or network mutation**.

`terraform output -json` yields the values to send back to Starfolk.

## Subnets: create or bring your own

Set **exactly one** of:

- **`subnet_cidrs`** — the module **creates** dedicated subnets from free space in
  your VPC (one per entry, one per AZ) and associates them with `route_table_id`.
  Best when you have spare CIDR space and want isolated, module-owned subnets.
- **`subnet_ids`** — the module attaches to **existing** subnets you pass. It
  creates no subnets, associates no route table (yours already route), and doesn't
  touch `map_public_ip_on_launch` (your subnet's own setting governs). Use this
  when your VPC has no spare CIDR space, or you want boxes in your existing private
  subnets. Hand us the subnet IDs.

```hcl
# Bring your own existing private subnets:
subnet_ids     = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]
route_table_id = null   # not needed — your subnets already route
# (omit subnet_cidrs / assign_public_ip — the subnets' own config governs)
```

With `subnet_ids`, if those subnets don't auto-assign public IPs (i.e. private
subnets), the hand-back's `access_mode` is emitted as **`vpn_private`**
automatically, so the coordinator addresses boxes by their private IP over your
VPN (see [Reaching boxes without a public IP](#reaching-boxes-without-a-public-ip)).

`isolate_from_cidrs` **works with `subnet_ids`**, but only if the subnets you pass
are **dedicated to SFK boxes** — the module attaches its NACL to those subnets,
which *replaces* their current ACL (a subnet has exactly one). If those subnets
also host other workloads, the isolation would apply to them too, so use dedicated
subnets (or leave `isolate_from_cidrs` unset and isolate via your own SGs — the
boxes carry the `sfk-devbox-sg` security group you can reference).

## Bring your own state & settings

The repo root is intentionally just the module — no `backend {}`, no
`provider {}`. That's what lets you **wrap** it with your own Terraform state
storage (S3, GCS, Terraform Cloud, …) and provider/auth config without editing
anything Starfolk ships. [`examples/wrapper/`](examples/wrapper/) is a complete,
copy-paste starting point: your S3 backend, your `provider "aws"`, a pinned
`module "sfk_byoc"` call, and the `sfk_handback` output. Copy that directory into
your own repo, adjust it, and apply.

## Route table requirements

(Applies only when the module **creates** subnets via `subnet_cidrs`. With
`subnet_ids` you bring existing subnets that already route, so `route_table_id` is
not used.)

We associate the dedicated subnets with the `route_table_id` you pass — we don't
create or modify a route table. That table **must** provide:

1. **A default route** `0.0.0.0/0` → an **Internet Gateway** (public postures A / A-VPN)
   or a **NAT gateway** (private postures B / C). Devboxes need outbound HTTPS to
   reach AWS SSM, the Starfolk coordinator, the tunnel lighthouse, GitHub, and
   package mirrors — **without egress a box never finishes provisioning** (it hangs
   in `PRE_WARMING`).
2. **Routes to the resources the agent must reach.** The **intra-VPC (local) route
   is automatic**, so resources in the *same* VPC just work. Resources in **peered
   VPCs, via Transit Gateway, or on-prem (VPN / Direct Connect)** are *not*
   automatic — pass a route table that already carries those routes (this is why we
   associate with your existing table rather than a bare new one).

Point us at a route table that already has both — typically the one your other
private workloads use. [`examples/routing/sample_router.tf`](examples/routing/sample_router.tf)
shows the shape (public + private + peering examples). If you'd prefer we create and own a dedicated route table for these
subnets instead (isolation, explicit egress target), tell us — it's a supported
variation, but a fresh table only sees the routes we add, so cross-network
reachability would need to be listed explicitly.

## How permissions / access work

You never give Starfolk a key. This role **trusts Starfolk to assume it**, gated by an external ID; Starfolk calls `sts:AssumeRole` for short-lived (1h) credentials. Revoke any time by removing the role. Every action lands in your CloudTrail. Starfolk only ever calls AWS API endpoints — it never connects *to* a box.

## Instance role: own it yourself

By default the module creates the `sfk-devbox` IAM role + instance profile (with
just `AmazonSSMManagedInstanceCore`, so the SSM agent registers). You don't have
to let it — two knobs give you control:

- **Bring your own.** Set `create_instance_profile = false` and pass
  `instance_profile_name` + `instance_role_arn`. The module then creates neither
  the role nor the profile; the coordinator launches with your profile, and the
  control role's `iam:PassRole` is pinned to exactly your `instance_role_arn`
  (nothing else is passable). Your role must carry SSM permissions
  (`AmazonSSMManagedInstanceCore` or equivalent) or the box never registers. Use
  this to run a role you author end-to-end — e.g. one with your own
  `DenyAnyAssumeRole` guardrail.
- **Keep ours, add the guardrail.** If you'd rather the module keep owning the
  role, set `deny_instance_role_assume_role = true` to attach a
  `DenyAnyAssumeRole` guardrail (Deny `sts:AssumeRole` on `*`) to it. The devbox
  never needs to assume another role, so this caps blast radius if a box is
  compromised.

```hcl
# Bring your own devbox role/profile:
create_instance_profile = false
instance_profile_name   = "my-devbox-profile"
instance_role_arn       = "arn:aws:iam::505307261329:role/my-devbox-role"

# — or — keep the module-created role but harden it:
deny_instance_role_assume_role = true
```

## Isolating boxes from co-tenant workloads

The module deploys into your **existing** VPC, so the devbox subnets sit
alongside whatever else you already run there. To wall the boxes off from a
neighbor, know what each control can and can't do:

- **A dedicated route table does *not* isolate them.** Every subnet has an
  implicit `local` route to the whole VPC CIDR that can't be removed, so routing
  can't stop intra-VPC reachability — it only steers *non-local* (internet,
  peered, TGW) traffic.
- **Security groups protect *inbound to the boxes*.** Our SG is default-deny
  inbound and opens only 22/443 (to `ssh_ingress_cidrs`), Nebula UDP, and — only
  when a web-session flag is enabled — 7681 (to the production coordinator EIP
  or explicitly supplied `coordinator_ingress_cidrs`), with
  no self-rule, so a neighbor can't open connections *to* the boxes. (Exception:
  posture A's `["0.0.0.0/0"]` on `ssh_ingress_cidrs` lets any in-VPC host reach
  22/443; scope it if that matters.) But the SG's egress is allow-all, so it does
  **not** stop the boxes from reaching *out* to a neighbor — that's the neighbor's
  own SG's job.

To fully wall the boxes off from specific neighbors in **both** directions, set
`isolate_from_cidrs` to those workloads' CIDRs:

```hcl
isolate_from_cidrs = ["10.0.20.0/24", "10.0.21.0/24"]  # co-tenant subnets
```

The module then attaches a **network ACL** to the devbox subnets that denies
those CIDRs inbound + outbound and allows everything else — the boxes keep full
internet/DNS/SSM but can't reach, or be reached by, the listed workloads. We use
a NACL (not an SG egress rule) because SGs are allow-only and can't express a
deny; NACLs are stateless, so the module's allow-all baseline carries return
traffic. **Don't** try to block the whole VPC CIDR this way — the boxes' in-VPC
dependencies (SSM interface endpoints, the VPC DNS resolver) live in the VPC
CIDR and would break; list only the specific neighbors.

### Dedicated vs shared subnets — which isolation tool

`isolate_from_cidrs` uses a **subnet-level** NACL, so it's only safe when the
boxes are on subnets **dedicated to SFK** (created via `subnet_cidrs`, or
bring-your-own subnets that host nothing else). On a subnet **shared** with other
workloads it would apply to those workloads too — so don't use it there.

**To isolate boxes on a shared subnet, use security groups (both directions) —
no NACL, no dedicated subnet:**

- **Inbound (neighbor → boxes):** already covered by `sfk-devbox-sg` (default-deny
  inbound). Scope `ssh_ingress_cidrs` to your VPN/admin CIDR only (not the VPC or
  the shared subnet), and set `enable_web_sessions=false` / `enable_nebula_ingress=false`
  for a private posture — then a co-tenant in the same subnet has no open port to
  the boxes.
- **Outbound (boxes → neighbor):** enforced on **your** side. Your neighbor
  workloads' SGs are default-deny inbound, so the boxes can't reach them unless
  you explicitly allow `sfk-devbox-sg`. Just don't add it to their allow-lists.
  The `security_group_id` is in the hand-back for exactly this SG-to-SG reference.

That SG-to-SG pattern is the standard way to isolate co-located workloads in a
shared subnet — so co-locating on your existing private subnets is fine and needs
no VPC change.

## Instance launch configuration (IMDSv2 + EBS encryption)

This module creates no instances and no launch template — the Starfolk
coordinator issues `RunInstances` directly (into the subnets, SG, and instance
profile above) each time it launches a box. Two security-relevant properties are
set on **every** launch, so you can confirm them (and, if you want, enforce them
from your side — see below):

- **IMDSv2 is required.** Every launch sets `MetadataOptions = { HttpTokens =
  "required", HttpPutResponseHopLimit = 2 }`, so IMDSv1 is disabled on the box.
- **The root EBS volume is always encrypted.** The devbox AMI's snapshot is
  encrypted under a Starfolk-owned CMK (`alias/sfk-devbox-shared`), and a volume
  created from an encrypted snapshot is itself encrypted under that same key — so
  the root volume is encrypted by construction regardless of the launch params.
  The volume is `gp3` with `DeleteOnTermination = true`.

Because the coordinator already complies, you can safely make this
**self-enforcing** with an SCP or IAM condition on `ec2:RunInstances` (e.g.
require `ec2:MetadataHttpTokens = required` and `ec2:Encrypted = true`) — those
guardrails pass rather than blocking launches. Public IP is **not** set on
`RunInstances`; it's inherited from the subnet's auto-assign setting, which this
module controls via `assign_public_ip`.

## Access postures → variables

Pick how users reach the boxes:

| Posture | `assign_public_ip` | `ssh_ingress_cidrs` | `enable_web_sessions` | `route_table_id` | Notes |
|---|---|---|---|---|---|
| **A** — public, open (easiest) | `true` | `["0.0.0.0/0"]` | `true` (optional) | public/IGW-routed | Today's direct-SSH flow; boxes internet-reachable. Enable the production coordinator for the browser terminal. |
| **A-VPN** — public, behind your VPN | `true` | `["<vpn-egress-cidr>"]` | `true` (optional) | public/IGW-routed | Same client, **zero code change**, but reachable only from your VPN. (ENI still has a public IP — won't pass a strict "no public IPs" Config rule.) |
| **B** — private, VPN → private IP | `false` (or `subnet_ids` = your private subnets) | `["<vpc-or-vpn-cidr>"]` | `false` | NAT-routed (or omit with `subnet_ids`) | No public IP; the coordinator addresses the box by its **private VPC IP** over your VPN when the account is registered `access_mode = vpn_private`. **Supported** — see [Reaching boxes without a public IP](#reaching-boxes-without-a-public-ip). |
| **C** — private, Nebula overlay | `false` | `[]` | `false` | NAT-routed | No public IP; reach via `sfk setup tunnel`. Overlay rides `nebula0`, so no 22/443 ingress. Alternative to posture B if you'd rather not route to the private IP yourself. |

`enable_web_sessions` (default `false`) opens TCP 7681 to the production
coordinator's stable `18.188.161.41/32` NAT egress address. Add
`coordinator_ingress_cidrs` only for a non-production or custom coordinator. Web
sessions require a public posture where the coordinator can route to the box;
SSM management works either way.

`enable_nebula_ingress` (default `true`) opens UDP 51820; harmless for postures that don't use the overlay.

## Reaching boxes without a public IP

Set `assign_public_ip = false` and the boxes get **no public IP** — the strict
`route_table_id` becomes NAT-routed and `enable_web_sessions` should stay `false`.
SSM control is unaffected (the coordinator drives boxes over the AWS SSM API, with
no inbound path to the box), so a private box still provisions and is managed
end-to-end. The question is how you *reach a shell* on it, and how it's addressed.

### How the coordinator addresses a box (and where DNS points)

The coordinator learns a box's IPs from EC2 `DescribeInstances` during its
warm-pool reconcile — it reads both `PublicIpAddress` and `PrivateIpAddress`. How
it *addresses* the box is set by the cloud account's `access_mode`:

- **`public`** (default) — the box's **public IP**: handed to `sfk devbox connect`,
  published as the friendly DNS record, and dialed for the browser terminal.
- **`vpn_private`** — the box's **private VPC IP**: the reconciler stores it as the
  box's reachable address, hands *it* to `sfk devbox connect`, and publishes it as
  the friendly DNS record. You reach the box by that private IP **over your VPN** —
  no Nebula, no public IP. (The browser web terminal doesn't apply here: the
  coordinator isn't on your VPN, so `enable_web_sessions` stays `false` and
  interactive access is SSH over the VPN. Control still runs over SSM, IP-independent.)

So there are **two** no-public-IP paths — pick one:

1. **VPN → private IP (posture B)** — recommended if you already reach private
   resources over a VPN. Give the boxes no public IP (either `assign_public_ip =
   false` on module-created subnets, or point `subnet_ids` at your existing private
   subnets), scope `ssh_ingress_cidrs` to your VPN CIDR, and register the account
   `access_mode = vpn_private`. The hand-back emits that `access_mode` automatically
   (from the subnet's auto-assign-public-IP setting), so you just paste it in. Your
   VPN must route to the subnets' CIDR.
2. **Nebula overlay (posture C)** — if you'd rather not route to the private IP
   yourself. Leave `enable_nebula_ingress = true` + `assign_public_ip = false`, run
   `sfk setup tunnel`; `<alias>.box.starfolk.ai` resolves to the box's overlay IP
   and traffic rides `nebula0` (no 22/443 ingress needed).

## Usage

```hcl
provider "aws" {
  region = "us-west-2"
  # your infra team's auth / assume-role config
}

module "sfk_byoc" {
  source = "github.com/starfolkai/terraform-aws-sfk-devbox?ref=1.1.1" # pin a reviewed tag

  region            = "us-west-2"                         # must match provider "aws" region
  vpc_id            = "vpc-0123456789abcdef0"          # your existing shared VPC
  subnet_cidrs      = ["10.4.16.0/20", "10.4.32.0/20"] # free space in your VPC, one per AZ
  route_table_id    = "rtb-0your_existing_igw_or_nat"  # the RT the subnets associate with

  # Posture A-VPN (public IP, reachable only from your VPN):
  assign_public_ip    = true
  ssh_ingress_cidrs   = ["203.0.113.0/24"] # your VPN egress CIDR
  enable_web_sessions = true                # TCP 7681 from Starfolk prod only

  sfk_principal_arn = "arn:aws:iam::450410490644:role/sfk-coordinator-remote-prod" # from Starfolk
  # external_id     = "..."   # omit to auto-generate; then send the output value back
}

output "sfk_handback" {
  value = {
    account_id        = module.sfk_byoc.account_id
    access_mode       = module.sfk_byoc.access_mode  # "public" | "vpn_private", from assign_public_ip
    region            = module.sfk_byoc.region
    role_arn          = module.sfk_byoc.role_arn
    external_id       = module.sfk_byoc.external_id
    subnet_ids        = module.sfk_byoc.subnet_ids
    security_group_id = module.sfk_byoc.security_group_id
    instance_profile  = module.sfk_byoc.instance_profile
  }
}
```

`region` currently supports only `us-east-2` and `us-west-2` and must match the
AWS provider region. It defaults to `us-east-2` for compatibility with releases
before 1.1.1; west-region callers must set it explicitly. The module uses it to
grant the control role access to the exact Starfolk-owned regional KMS key that
encrypts the shared devbox AMI; KMS keys cannot decrypt EBS snapshots in another
region. The old `ami_kms_key_arns` input remains only as a validated compatibility
override; new callers should omit it and let `region` select the key.

The `access_mode` output is derived from `assign_public_ip` (`public` when boxes get public IPs, `vpn_private` when they don't) — it tells Starfolk how to register the account so the coordinator addresses boxes correctly (public IP vs. private-IP-over-VPN). Send it back with the rest.

`terraform init && terraform plan` → review with your security team → `terraform apply`, then send the `sfk_handback` output to Starfolk.

## Registering with Starfolk (the second half)

This module creates the AWS side. Registering these values with your Starfolk
environment is a separate step — send Starfolk the `sfk_handback` output via slack. There are no secrets here- only AWS ARNs

## Requirements

- Terraform >= 1.5, AWS provider >= 5.0, random provider >= 3.0.
- Credentials for your account able to create EC2 (subnets/SG) + IAM (roles/instance profile).
