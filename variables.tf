variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  description = "Name/tag prefix for all resources."
  type        = string
  default     = "wg-vpn"
}

variable "instance_type" {
  type    = string
  default = "t4g.nano"
}

variable "wg_port" {
  type    = number
  default = 51820
}

variable "wg_net" {
  description = "First three octets of the WireGuard /24 (server .1, client .2)."
  type        = string
  default     = "10.8.0"
}

variable "client_dns" {
  description = "DNS server pushed to the client while the tunnel is up."
  type        = string
  default     = "1.1.1.1"
}

variable "dns_name" {
  description = "Hostname clients dial. Must match the delegated Route53 zone. Set your real value via ./setup.sh (lands in the git-ignored terraform.tfvars)."
  type        = string
  default     = "vpn.example.com"
}

# Written to terraform.tfvars by ./setup.sh (run once before `terraform apply`).
variable "client_public_key" {
  description = "WireGuard public key of the Mac client."
  type        = string
}
