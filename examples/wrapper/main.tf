# Example: wrap the Starfolk BYOC module with YOUR OWN Terraform state backend
# and provider/auth settings.
#
# The repo root is a plain module — it declares NO backend and NO provider on
# purpose, so you own those. Copy this directory into your own infrastructure
# repo, change the backend + provider + inputs to match your environment, then:
#
#   terraform init && terraform plan   # review with your security team
#   terraform apply
#   terraform output -json sfk_handback   # send this back to Starfolk
#
# Pin `source` to a release tag you have reviewed — never float on the default
# branch for something that creates IAM roles in your account.

terraform {
  required_version = ">= 1.10"

  # ── YOUR state backend. This is the "bring your own storage" part — replace
  #    the whole block with whatever your team already uses (S3, GCS, Terraform
  #    Cloud, Consul, local, …). Starfolk never sees your state. ──
  backend "s3" {
    bucket       = "my-company-terraform-state"
    key          = "sfk-byoc/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true # native S3 locking (Terraform >= 1.10); or dynamodb_table = "…"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ── YOUR provider / auth config. ──
provider "aws" {
  region = "us-west-2"
  # profile = "my-company-infra"        # or:
  # assume_role { role_arn = "arn:aws:iam::…:role/terraform" }
}

module "sfk_byoc" {
  source = "github.com/starfolkai/terraform-aws-sfk-devbox?ref=v1.0.0"

  vpc_id         = "vpc-0123456789abcdef0"          # your existing shared VPC
  subnet_cidrs   = ["10.4.16.0/20", "10.4.32.0/20"] # free space in your VPC, one per AZ
  route_table_id = "rtb-0your_existing_igw_or_nat"  # RT the subnets associate with

  # Access posture A-VPN — public IP, reachable only from your VPN egress:
  assign_public_ip  = true
  ssh_ingress_cidrs = ["203.0.113.0/24"] # your VPN egress CIDR

  # Values Starfolk gives you:
  sfk_principal_arn = "arn:aws:iam::450410490644:role/sfk-coordinator-remote-prod"
  # coordinator_ingress_cidrs = ["<starfolk-coordinator-egress>/32"]  # tighten 7681
  # external_id               = "…"   # omit to auto-generate, then send the output back
}

# Send this whole object back to Starfolk (paste into the Cloud Accounts admin
# console, or hand to your Starfolk contact). external_id is not a secret.
output "sfk_handback" {
  value = {
    account_id        = module.sfk_byoc.account_id
    access_mode       = module.sfk_byoc.access_mode
    region            = module.sfk_byoc.region
    role_arn          = module.sfk_byoc.role_arn
    external_id       = module.sfk_byoc.external_id
    subnet_ids        = module.sfk_byoc.subnet_ids
    security_group_id = module.sfk_byoc.security_group_id
    instance_profile  = module.sfk_byoc.instance_profile
  }
}
