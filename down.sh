#!/usr/bin/env bash
#
# down.sh — stop the instance after a session. Keeps the EBS volume, the server
# key, the DNS name and the Route53 zone, so ./up.sh is fast next time and you
# never re-import. Only the compute bill stops.
#
set -euo pipefail
cd "$(dirname "$0")"

REGION="${REGION:-eu-central-1}"

ID="$(terraform output -raw instance_id 2>/dev/null || true)"
[ -n "$ID" ] || { echo "No instance in Terraform state — nothing to stop."; exit 0; }

echo ">> stopping instance $ID"
aws ec2 stop-instances --region "$REGION" --instance-ids "$ID" >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$ID"
echo ">> stopped. Compute billing paused (idle cost ~\$1.90/mo: EBS + Route53 zone + 2 secrets). Run ./up.sh to resume."
