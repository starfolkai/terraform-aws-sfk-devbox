# Sample route table for Starfolk BYOC devbox subnets.
#
# The byoc-terraform module associates its dedicated subnets with a route table
# YOU provide (var.route_table_id) — it does not create one. This file shows the
# shape of a suitable table for each access posture; copy the block you need into
# your own config, or just point the module at an existing equivalent table.
#
# This lives in examples/ on purpose: Terraform does not load module
# subdirectories, so this is a reference only — it is NOT applied as part of the
# module. Adapt the ids to your VPC before using.
#
# The "public" table below (VPC + IGW + a route table with 0.0.0.0/0 → IGW,
# passed to the module as route_table_id) is the posture-A shape.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "vpc_id" {
  type        = string
  description = "The existing VPC the devbox subnets live in."
}

variable "internet_gateway_id" {
  type        = string
  description = "IGW attached to the VPC (public postures A / A-VPN)."
  default     = ""
}

variable "nat_gateway_id" {
  type        = string
  description = "NAT gateway in the VPC (private postures B / C)."
  default     = ""
}

# ── Public posture (A / A-VPN): default route → Internet Gateway ─────────────
# Devboxes get a public IP and egress straight out the IGW. This is what the
# test harness creates. Pass this table's id to the module as route_table_id.
resource "aws_route_table" "byoc_public" {
  vpc_id = var.vpc_id
  tags   = { Name = "byoc-devbox-public" }
}

resource "aws_route" "byoc_public_default" {
  route_table_id         = aws_route_table.byoc_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = var.internet_gateway_id
}

# The intra-VPC (local) route is automatic — resources in THIS VPC are reachable
# with no extra routes. For resources beyond the VPC (peered VPC / Transit
# Gateway / on-prem), add explicit routes so the agent can reach them, e.g.:
#
# resource "aws_route" "byoc_to_peered_db" {
#   route_table_id            = aws_route_table.byoc_public.id
#   destination_cidr_block    = "10.20.0.0/16"        # the peered VPC / on-prem CIDR
#   vpc_peering_connection_id = "pcx-0123456789abcdef" # or transit_gateway_id = "tgw-…"
# }

output "route_table_id" {
  description = "Feed this to the byoc-terraform module as route_table_id."
  value       = aws_route_table.byoc_public.id
}

# ── Private posture (B / C): default route → NAT gateway ─────────────────────
# No public IP; egress via NAT. Reached via your VPN (B) or the Nebula overlay
# (C). Use this table instead of the public one above (set assign_public_ip=false
# on the module) — uncomment and pass nat_gateway_id.
#
# resource "aws_route_table" "byoc_private" {
#   vpc_id = var.vpc_id
#   tags   = { Name = "byoc-devbox-private" }
# }
#
# resource "aws_route" "byoc_private_default" {
#   route_table_id         = aws_route_table.byoc_private.id
#   destination_cidr_block = "0.0.0.0/0"
#   nat_gateway_id         = var.nat_gateway_id
# }
