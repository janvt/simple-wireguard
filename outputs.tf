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
