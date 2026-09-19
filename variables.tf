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

# Written to terraform.tfvars by ./setup.sh, which owns the profile list. Each entry
# is one WireGuard peer: its own key pair (private half stays on your Mac) and its own
# address in the tunnel subnet, so several devices/people can be connected at once.
#
# Terraform only publishes this to an SSM parameter; the instance syncs its peers from
# there at boot and on a timer, so adding or removing a profile never rebuilds the box.
variable "peers" {
  description = "WireGuard peers, keyed by profile name. Managed by ./setup.sh."
  type = map(object({
    public_key = string
    ip_suffix  = number
  }))

  validation {
    condition     = length(var.peers) > 0
    error_message = "At least one peer is required. Run ./setup.sh to create a profile."
  }

  validation {
    # .1 is the server; .0 and .255 are network/broadcast.
    condition     = alltrue([for p in var.peers : p.ip_suffix > 1 && p.ip_suffix < 255])
    error_message = "Each ip_suffix must be between 2 and 254 (the server holds .1)."
  }

  validation {
    condition     = length(distinct([for p in var.peers : p.ip_suffix])) == length(var.peers)
    error_message = "Two profiles share an ip_suffix. Fix client/profiles.tsv and re-run ./setup.sh."
  }

  validation {
    condition     = length(distinct([for p in var.peers : p.public_key])) == length(var.peers)
    error_message = "Two profiles share a public key. Each profile needs its own key pair."
  }
}
