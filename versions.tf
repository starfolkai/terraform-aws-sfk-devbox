terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.13" # NLB security-group support and updates.
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}
