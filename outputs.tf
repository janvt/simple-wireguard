output "endpoint" {
  description = "What the client dials."
  value       = "${var.dns_name}:${var.wg_port}"
}

output "instance_id" {
  value = aws_instance.vpn.id
}

output "security_group_id" {
  value = aws_security_group.wg.id
}

output "dns_name" {
  value = var.dns_name
}

output "wg_port" {
  value = var.wg_port
}

output "ready_param" {
  description = "SSM parameter the instance stamps with its id once boot setup finishes."
  value       = aws_ssm_parameter.ready.name
}

output "peers_param" {
  description = "SSM parameter holding the peer list the instance syncs from."
  value       = aws_ssm_parameter.peers.name
}

output "profiles" {
  description = "Profile name -> tunnel IP."
  value       = { for n, p in var.peers : n => "${var.wg_net}.${p.ip_suffix}" }
}

output "server_pubkey_param" {
  description = "SSM parameter the instance publishes its public key to."
  value       = aws_ssm_parameter.server_pubkey.name
}

output "secret_arn" {
  value = aws_secretsmanager_secret.server_key.arn
}

output "preshared_key_secret_arn" {
  value = aws_secretsmanager_secret.preshared_key.arn
}
