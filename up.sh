#!/usr/bin/env bash
#
# up.sh — bring the (already-provisioned) VPN up for a session. Does NOT run
# terraform. It: starts the instance, points vpn.<domain> at its new public IP,
# opens the firewall to your current IP, and (first time) renders the client config.
#
# Provision/rebuild the box yourself with:  ./setup.sh && terraform apply
#
set -euo pipefail
cd "$(dirname "$0")"

REGION="${REGION:-eu-central-1}"
MODE="${MODE:-split}"   # split = only proxied domains tunnelled; full = everything
CLIENT_DIR="client"
CLIENT_KEY="$CLIENT_DIR/client.key"
# Mode-specific filename → each mode is a separate, independently-importable tunnel
# in the WireGuard app (wg-vpn-split / wg-vpn-full).
CLIENT_CONF="$CLIENT_DIR/wg-vpn-${MODE}.conf"
WG_NET="10.8.0"
WG_PORT="51820"
CLIENT_DNS="1.1.1.1"

# --- read Terraform outputs (the box must already be applied) ---
ID="$(terraform output -raw instance_id 2>/dev/null || true)"
case "$ID" in
  i-*) : ;;
  *) echo "ERROR: no instance in Terraform state. Run './setup.sh && terraform apply' first."; exit 1 ;;
esac
SG="$(terraform output -raw security_group_id)"
DNS_NAME="$(terraform output -raw dns_name)"
PARAM="$(terraform output -raw server_pubkey_param)"
PSK_ARN="$(terraform output -raw preshared_key_secret_arn)"

# --- start it ---
echo ">> starting $ID"
aws ec2 start-instances --region "$REGION" --instance-ids "$ID" >/dev/null
aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"

PUBIP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
{ [ -n "$PUBIP" ] && [ "$PUBIP" != "None" ]; } || { echo "ERROR: instance has no public IP"; exit 1; }
echo ">> instance public IP: $PUBIP"

# --- open the firewall to my current source IP (replace any previous WG rule) ---
MYIP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
[ -n "$MYIP" ] || { echo "ERROR: could not determine my public IP"; exit 1; }
echo ">> locking ingress to ${MYIP}/32"
for cidr in $(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG" \
  --query "SecurityGroups[0].IpPermissions[?ToPort==\`${WG_PORT}\`].IpRanges[].CidrIp" --output text); do
  aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG" \
    --protocol udp --port "$WG_PORT" --cidr "$cidr" >/dev/null || true
done
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol udp --port "$WG_PORT" --cidr "${MYIP}/32" >/dev/null

# --- point vpn.<domain> at the instance ---
ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$DNS_NAME" \
  --query 'HostedZones[0].Id' --output text | sed 's#/hostedzone/##')"
{ [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ]; } || { echo "ERROR: hosted zone for $DNS_NAME not found"; exit 1; }
echo ">> updating DNS $DNS_NAME -> $PUBIP"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
  \"Changes\": [{
    \"Action\": \"UPSERT\",
    \"ResourceRecordSet\": {
      \"Name\": \"${DNS_NAME}\", \"Type\": \"A\", \"TTL\": 60,
      \"ResourceRecords\": [{\"Value\": \"${PUBIP}\"}]
    }
  }]
}" >/dev/null

# --- render the client config (first time only; it's stable across sessions) ---
if [ ! -f "$CLIENT_CONF" ]; then
  [ -f "$CLIENT_KEY" ] || { echo "ERROR: $CLIENT_KEY missing — run ./setup.sh first."; exit 1; }
  echo ">> waiting for the server to publish its key (fresh boot only)"
  SERVER_PUB=""
  for _ in $(seq 1 60); do
    SERVER_PUB="$(aws ssm get-parameter --region "$REGION" --name "$PARAM" --query 'Parameter.Value' --output text 2>/dev/null || true)"
    { [ -n "$SERVER_PUB" ] && [ "$SERVER_PUB" != "placeholder" ] && [ "$SERVER_PUB" != "None" ]; } && break
    sleep 3
  done
  { [ -n "$SERVER_PUB" ] && [ "$SERVER_PUB" != "placeholder" ] && [ "$SERVER_PUB" != "None" ]; } \
    || { echo "ERROR: server not ready yet — re-run ./up.sh in a moment"; exit 1; }

  PSK=""
  for _ in $(seq 1 20); do
    PSK="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$PSK_ARN" --query SecretString --output text 2>/dev/null || true)"
    { [ -n "$PSK" ] && [ "$PSK" != "None" ]; } && break
    sleep 3
  done
  { [ -n "$PSK" ] && [ "$PSK" != "None" ]; } || { echo "ERROR: pre-shared key not ready — re-run ./up.sh in a moment"; exit 1; }

  if [ "$MODE" = "full" ]; then
    ALLOWED="0.0.0.0/0, ::/0"; DNSLINE="DNS = ${CLIENT_DNS}"
  else
    ALLOWED="${WG_NET}.0/24"; DNSLINE=""
  fi
  CLIENT_PRIV="$(cat "$CLIENT_KEY")"
  ( umask 077; cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_NET}.2/32
${DNSLINE}
[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${DNS_NAME}:${WG_PORT}
AllowedIPs = ${ALLOWED}
PersistentKeepalive = 25
EOF
)
  echo ">> wrote $CLIENT_CONF — import it into WireGuard once"
fi

# --- (re)generate the PAC from domains.txt each run so edits take effect ---
if [ "$MODE" != "full" ]; then
  # PAC is served over http://127.0.0.1:8899 (see pac-server launchd agent), because
  # macOS silently ignores file:// PAC URLs. It lives in its own dir — never serve
  # client/, which holds your keys. The PAC itself contains no secrets.
  DOMAINS_FILE="$CLIENT_DIR/domains.txt"
  PAC_DIR="pac"; PAC_FILE="$PAC_DIR/discovery.pac"
  mkdir -p "$PAC_DIR"
  [ -f "$DOMAINS_FILE" ] || printf '%s\n' "discovery.com" "discoveryplus.com" > "$DOMAINS_FILE"
  {
    echo "function FindProxyForURL(url, host) {"
    echo "  var proxy = \"PROXY ${WG_NET}.1:3128; DIRECT\";"
    while IFS= read -r line; do
      d="${line%%#*}"; d="$(printf '%s' "$d" | tr -d '[:space:]')"; [ -z "$d" ] && continue
      echo "  if (shExpMatch(host, \"$d\") || shExpMatch(host, \"*.$d\")) return proxy;"
    done < "$DOMAINS_FILE"
    echo "  return \"DIRECT\";"
    echo "}"
  } > "$PAC_FILE"
fi

TUNNEL_NAME="$(basename "${CLIENT_CONF%.conf}")"
echo
echo "VPN UP (mode: ${MODE}).  ${DNS_NAME}:${WG_PORT} -> ${PUBIP}"
echo "Config: ${CLIENT_CONF}  (WireGuard tunnel name: ${TUNNEL_NAME})"
echo "Import it once if new, then toggle that tunnel ON. Only one tunnel at a time"
echo "(both modes share the same client key). Done watching?  ./down.sh"
