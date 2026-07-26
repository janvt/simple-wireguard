# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ---------------------------------------------------------------------------
# Security group — the SHELL only. Egress is open (a VPN must forward out).
# The INGRESS rule (WireGuard UDP from your current IP) is managed by up.sh via
# the AWS CLI, because your source IP changes between sessions. Using a separate
# rule resource model means Terraform never touches up.sh's out-of-band rule.
# ---------------------------------------------------------------------------
resource "aws_security_group" "wg" {
  name        = "${var.name}-sg"
  description = "WireGuard VPN (UDP ${var.wg_port})"
  vpc_id      = data.aws_vpc.default.id
  tags        = { Name = "${var.name}-sg" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.wg.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# IAM: SSM access + read/write only the one secret and the one SSM parameter.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpn" {
  name               = "${var.name}-ssm"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vpn.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "secret_access" {
  statement {
    sid     = "ServerKey"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = [
      aws_secretsmanager_secret.server_key.arn,
      aws_secretsmanager_secret.preshared_key.arn,
    ]
  }
  statement {
    sid       = "ServerPubKeyParam"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter${aws_ssm_parameter.server_pubkey.name}"]
  }
}

resource "aws_iam_role_policy" "secret_access" {
  name   = "wg-secret-access"
  role   = aws_iam_role.vpn.id
  policy = data.aws_iam_policy_document.secret_access.json
}

resource "aws_iam_instance_profile" "vpn" {
  name = "${var.name}-ssm"
  role = aws_iam_role.vpn.name
}

# ---------------------------------------------------------------------------
# Secret material containers. The INSTANCE writes the values at boot; Terraform
# only manages the empty containers, so no private key ever lands in TF state.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "server_key" {
  name                    = "${var.name}/server-private-key"
  description             = "WireGuard server private key (written by the instance at boot)"
  recovery_window_in_days = 0 # allow immediate delete + recreate
}

resource "aws_secretsmanager_secret" "preshared_key" {
  name                    = "${var.name}/preshared-key"
  description             = "WireGuard peer pre-shared key (written by the instance at boot)"
  recovery_window_in_days = 0
}

resource "aws_ssm_parameter" "server_pubkey" {
  name        = "/${var.name}/server-public-key"
  description = "WireGuard server public key (published by the instance; not sensitive)"
  type        = "String"
  value       = "placeholder"
  lifecycle {
    ignore_changes = [value] # the instance overwrites this at boot
  }
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------
resource "aws_instance" "vpn" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.wg.id]
  iam_instance_profile        = aws_iam_instance_profile.vpn.name
  associate_public_ip_address = true
  source_dest_check           = false # required: this box forwards/NATs traffic

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region            = var.region
    priv_secret_id    = aws_secretsmanager_secret.server_key.arn
    psk_secret_id     = aws_secretsmanager_secret.preshared_key.arn
    param_name        = aws_ssm_parameter.server_pubkey.name
    client_public_key = var.client_public_key
    wg_net            = var.wg_net
    wg_port           = var.wg_port
  })
  # user_data runs only on first boot; don't replace the instance if it changes.
  user_data_replace_on_change = false

  tags = { Name = var.name }

  depends_on = [
    aws_iam_role_policy.secret_access,
    aws_iam_role_policy_attachment.ssm,
  ]
}

# NOTE: the vpn.<domain> A record is NOT managed here. Because there's no Elastic
# IP, the public IP changes on every start, so up.sh upserts the record (via the
# AWS CLI) each time it brings the instance up. Keeping it out of Terraform avoids
# state drift on a manual `terraform apply`.
