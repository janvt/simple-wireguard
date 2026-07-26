# One-time, durable delegation target. Apply this once, paste the resulting
# name_servers into Cloudflare as NS records for the subdomain, and then leave it
# alone — destroying/recreating it changes the name servers and breaks delegation.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "dns_name" {
  type    = string
  default = "vpn.example.com" # set your real value via ../setup.sh -> dns/terraform.tfvars
}

resource "aws_route53_zone" "vpn" {
  name = var.dns_name
  tags = { Name = "wg-vpn" }
}

output "name_servers" {
  description = "Add these as NS records at Cloudflare for the subdomain."
  value       = aws_route53_zone.vpn.name_servers
}

output "zone_id" {
  value = aws_route53_zone.vpn.zone_id
}
