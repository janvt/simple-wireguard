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
# Security group. Egress is open (a VPN must forward out); ingress is WireGuard's
# UDP port, open to the internet.
#
# Open is the normal way to run WireGuard, not a concession. The daemon never answers
# an unauthenticated packet — to a scanner the port looks closed — and the handshake
# is gated on a MAC keyed to the server's public key, checked before any Curve25519
# work, so an unauthenticated peer can't even make the box do crypto. A pre-shared key
# sits on top of that.
#
# A source-IP lock used to live in up.sh, but a security group filters on port, not on
# WireGuard identity: it's all-or-nothing across every peer, so it cannot express
# "my Mac plus whatever address a friend happens to dial in from today".
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

resource "aws_vpc_security_group_ingress_rule" "wg" {
  security_group_id = aws_security_group.wg.id
  description       = "WireGuard"
  ip_protocol       = "udp"
  from_port         = var.wg_port
  to_port           = var.wg_port
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
    sid     = "ServerPubKeyParam"
    actions = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:*:parameter${aws_ssm_parameter.server_pubkey.name}",
      "arn:aws:ssm:${var.region}:*:parameter${aws_ssm_parameter.ready.name}",
    ]
  }
  statement {
    sid       = "PublishUsageMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData has no resource ARNs; the namespace condition scopes it
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metrics_namespace]
    }
  }
  statement {
    sid       = "PeerListParam"
    actions   = ["ssm:GetParameter"] # read-only: only Terraform writes the peer list
    resources = ["arn:aws:ssm:${var.region}:*:parameter${aws_ssm_parameter.peers.name}"]
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

# The peer list the instance syncs from. Public keys only — nothing secret here, so a
# plain String parameter is fine. Terraform owns the value; the instance only reads it.
# Keeping peers OUT of user-data is what lets you add or remove a profile without
# replacing the instance: change the list, apply, and the box picks it up within ~2 min.
resource "aws_ssm_parameter" "peers" {
  name        = "/${var.name}/peers"
  description = "WireGuard peers: one 'name pubkey ip_suffix' line per profile"
  type        = "String"
  value       = join("\n", [for n in sort(keys(var.peers)) : "${n} ${var.peers[n].public_key} ${var.peers[n].ip_suffix}"])
}

# Written by the instance at the very end of user-data, with its own instance id.
# Terraform seeds it and then ignores the value.
resource "aws_ssm_parameter" "ready" {
  name        = "/${var.name}/ready"
  description = "Instance id of the box that last finished its boot setup"
  type        = "String"
  value       = "placeholder"
  lifecycle {
    ignore_changes = [value]
  }
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
    region         = var.region
    priv_secret_id = aws_secretsmanager_secret.server_key.arn
    psk_secret_id  = aws_secretsmanager_secret.preshared_key.arn
    param_name     = aws_ssm_parameter.server_pubkey.name
    peers_param    = aws_ssm_parameter.peers.name
    ready_param    = aws_ssm_parameter.ready.name
    namespace      = var.metrics_namespace
    usage_metrics  = var.enable_usage_metrics ? "true" : "false"
    wg_net         = var.wg_net
    wg_port        = var.wg_port
  })
  # user-data only runs on first boot, so a change to it must replace the instance to
  # take effect. That's safe here: the box is pure cattle — the server key and the
  # pre-shared key live in Secrets Manager and are re-fetched, so a replacement comes
  # back with the same identity and every handed-out client config keeps working.
  # Note this does NOT fire when you add or remove a profile: peers live in an SSM
  # parameter, so user-data's content is unchanged by a profile edit.
  user_data_replace_on_change = true

  tags = { Name = var.name }

  depends_on = [
    aws_iam_role_policy.secret_access,
    aws_iam_role_policy_attachment.ssm,
  ]
}

# NOTE: the vpn.<domain> A record is NOT managed here. Because there's no Elastic
# IP, the public IP changes on every start, so up.sh upserts the record (via the
# AWS CLI) each time it brings the instance up. Keeping it out of Terraform avoids
# state drift on a manual `terraform apply`. It's the only piece still managed
# out-of-band — the SG ingress rule used to be too, back when it tracked your IP.

# ---------------------------------------------------------------------------
# Usage dashboard. The instance publishes per-interval deltas per profile; these
# widgets Sum them, so every number reads as "bytes in the selected window".
#
# BytesToPeer is the billable direction (data leaving AWS for a client), which is why
# it leads. The NetworkOut widget is the reality check: it's what AWS actually meters,
# and it runs a few percent above the tunnel counters because it includes the UDP and
# WireGuard encapsulation that the peer counters don't.
# ---------------------------------------------------------------------------
locals {
  profile_names = sort(keys(var.peers))
  month_seconds = 2592000 # 30 days, matching the widgets' -P30D window

  # Cost is derived from NetworkOut, the figure AWS actually meters, rather than from
  # the tunnel counters — those undercount by the UDP/WireGuard encapsulation. The
  # per-peer counters are then used only to SPLIT that total, and since the overhead
  # applies evenly to every peer it cancels out of the ratio.
  #
  # Splitting the overage pro-rata is a choice: the free allowance is consumed in
  # aggregate, so there is no non-arbitrary way to say whose bytes were the free ones.
  expr_gb_out     = "n0/1073741824"
  expr_cost_total = "IF(gb>${var.free_egress_gb}, (gb-${var.free_egress_gb})*${var.egress_price_per_gb}, 0)"

  cost_hidden_metrics = concat(
    [["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.vpn.id,
    { id = "n0", visible = false, stat = "Sum", period = 2592000 }]],
    [[{ expression = local.expr_gb_out, label = "GB", id = "gb", visible = false }]],
    [for i, n in local.profile_names :
      [var.metrics_namespace, "BytesToPeer", "Profile", n,
      { id = "m${i}", visible = false, stat = "Sum", period = 2592000 }]
    ],
    [[{ expression = "SUM([${join(",", [for i, n in local.profile_names : "m${i}"])}])", label = "tot", id = "tot", visible = false }]],
  )
}

resource "aws_cloudwatch_dashboard" "vpn" {
  count          = var.enable_usage_metrics ? 1 : 0
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Egress to peers — the direction AWS bills"
          region  = var.region
          view    = "timeSeries"
          stacked = true
          stat    = "Sum"
          period  = 300
          metrics = [for n in local.profile_names : [var.metrics_namespace, "BytesToPeer", "Profile", n]]
          yAxis   = { left = { label = "Bytes", showUnits = false } }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Ingress from peers (inbound is free)"
          region  = var.region
          view    = "timeSeries"
          stacked = true
          stat    = "Sum"
          period  = 300
          metrics = [for n in local.profile_names : [var.metrics_namespace, "BytesFromPeer", "Profile", n]]
          yAxis   = { left = { label = "Bytes", showUnits = false } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 6
        height = 6
        properties = {
          title  = "Free allowance used (30d)"
          region = var.region
          view   = "gauge"
          period = local.month_seconds
          start  = "-P30D"
          metrics = [
            [{ expression = "n0/1073741824", label = "GB out", id = "gb" }],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.vpn.id,
            { id = "n0", visible = false, stat = "Sum", period = local.month_seconds }],
          ]
          yAxis = { left = { min = 0, max = var.free_egress_gb } }
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 6
        width  = 9
        height = 6
        properties = {
          title  = "Estimated egress cost (30d, USD)"
          region = var.region
          view   = "singleValue"
          period = local.month_seconds
          start  = "-P30D"
          metrics = concat(
            local.cost_hidden_metrics,
            [[{ expression = local.expr_cost_total, label = "Total", id = "ct" }]],
            [for i, n in local.profile_names :
              [{ expression = "IF(tot>0, ct*m${i}/tot, 0)", label = n, id = "c${i}" }]
            ],
          )
        }
      },
      {
        type   = "metric"
        x      = 15
        y      = 6
        width  = 9
        height = 6
        properties = {
          title  = "GB to each profile (30d)"
          region = var.region
          view   = "singleValue"
          period = local.month_seconds
          start  = "-P30D"
          metrics = concat(
            [for i, n in local.profile_names :
              [var.metrics_namespace, "BytesToPeer", "Profile", n,
              { id = "g${i}", visible = false, stat = "Sum", period = local.month_seconds }]
            ],
            [for i, n in local.profile_names :
              [{ expression = "g${i}/1073741824", label = n, id = "x${i}" }]
            ],
          )
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title   = "Instance NetworkOut — what AWS actually meters"
          region  = var.region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 300
          metrics = [["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.vpn.id]]
          yAxis   = { left = { label = "Bytes", showUnits = false } }
        }
      },
    ]
  })
}
