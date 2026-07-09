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

- **Dedicated subnets** (one per `subnet_cidrs` entry) in your `vpc_id`, associated with a route table you already have (`route_table_id`) — we never create or mutate your VPC/IGW/NAT/routing.
- **Security group** with posture-appropriate ingress.
- **Instance profile** `sfk-devbox` (+ `AmazonSSMManagedInstanceCore`) so the box's SSM agent registers in your account.
- **Control role** `sfk-devbox-control`, assumed by Starfolk (trust = SFK principal **+ external id**). Least-privilege: `iam:PassRole` pinned to the `sfk-devbox` role ARN, `ec2:RunInstances` pinned to the created subnet + SG ARNs, `ssm:SendCommand` tag-scoped to `sfk:<stage>:managed` instances, destructive EC2 actions tag-gated, and **no `sts:*` / no IAM or network mutation**.

`terraform output -json` yields the values to send back to Starfolk.

## Bring your own state & settings

The repo root is intentionally just the module — no `backend {}`, no
`provider {}`. That's what lets you **wrap** it with your own Terraform state
storage (S3, GCS, Terraform Cloud, …) and provider/auth config without editing
anything Starfolk ships. [`examples/wrapper/`](examples/wrapper/) is a complete,
copy-paste starting point: your S3 backend, your `provider "aws"`, a pinned
`module "sfk_byoc"` call, and the `sfk_handback` output. Copy that directory into
your own repo, adjust it, and apply.

## Route table requirements

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

## Access postures → variables

Pick how users reach the boxes:

| Posture | `assign_public_ip` | `ssh_ingress_cidrs` | `route_table_id` | Notes |
|---|---|---|---|---|
| **A** — public, open (easiest) | `true` | `["0.0.0.0/0"]` | public/IGW-routed | Today's direct-SSH flow; boxes internet-reachable. |
| **A-VPN** — public, behind your VPN | `true` | `["<vpn-egress-cidr>"]` | public/IGW-routed | Same client, **zero code change**, but reachable only from your VPN. (ENI still has a public IP — won't pass a strict "no public IPs" Config rule.) |
| **B** — private, your VPN → private IP | `false` | `["<vpc-or-vpn-cidr>"]` | NAT-routed | No public IP; reach the private IP over your VPN (contact Starfolk to enable). |
| **C** — private, Nebula overlay | `false` | `[]` | NAT-routed | No public IP; reach via `sfk setup tunnel`. Overlay rides `nebula0`, so no 22/443 ingress. |

`enable_nebula_ingress` (default `true`) opens UDP 51820; harmless for postures that don't use the overlay.

## Usage

```hcl
provider "aws" {
  region = "us-west-2"
  # your infra team's auth / assume-role config
}

module "sfk_byoc" {
  source = "github.com/starfolkai/terraform-aws-sfk-devbox?ref=v1.0.0" # pin a reviewed tag

  vpc_id            = "vpc-0123456789abcdef0"          # your existing shared VPC
  subnet_cidrs      = ["10.4.16.0/20", "10.4.32.0/20"] # free space in your VPC, one per AZ
  route_table_id    = "rtb-0your_existing_igw_or_nat"  # the RT the subnets associate with

  # Posture A-VPN (public IP, reachable only from your VPN):
  assign_public_ip  = true
  ssh_ingress_cidrs = ["203.0.113.0/24"]               # your VPN egress CIDR

  sfk_principal_arn = "arn:aws:iam::450410490644:role/sfk-coordinator-remote-prod" # from Starfolk
  # external_id     = "..."   # omit to auto-generate; then send the output value back
}

output "sfk_handback" {
  value = {
    account_id        = module.sfk_byoc.account_id
    region            = module.sfk_byoc.region
    role_arn          = module.sfk_byoc.role_arn
    external_id       = module.sfk_byoc.external_id
    subnet_ids        = module.sfk_byoc.subnet_ids
    security_group_id = module.sfk_byoc.security_group_id
    instance_profile  = module.sfk_byoc.instance_profile
  }
}
```

`terraform init && terraform plan` → review with your security team → `terraform apply`, then send the `sfk_handback` output to Starfolk.

## Registering with Starfolk (the second half)

This module creates the AWS side. Registering these values with your Starfolk
environment is a separate step — send Starfolk the `sfk_handback` output.

## Requirements

- Terraform >= 1.5, AWS provider >= 5.0, random provider >= 3.0.
- Credentials for your account able to create EC2 (subnets/SG) + IAM (roles/instance profile).
