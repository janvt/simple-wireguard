#!/usr/bin/env bash
#
# up.sh — bring the (already-provisioned) VPN up for a session. Does NOT run
# terraform. It: starts the instance, points vpn.<domain> at its new public IP, and
# renders a client config for every profile that lacks one.
#
# The firewall is no longer touched here — UDP 51820 is open, and Terraform owns that
# rule (see main.tf). Nothing about it varies per session any more.
#
# Provision/rebuild the box yourself with:  ./setup.sh && terraform apply
# Manage profiles with:                     ./setup.sh add|rm|list
#
set -euo pipefail
cd "$(dirname "$0")"

REGION="${REGION:-eu-central-1}"
CLIENT_DIR="client"
MANIFEST="$CLIENT_DIR/profiles.tsv"
WG_NET="10.8.0"
WG_PORT="51820"
CLIENT_DNS="1.1.1.1"

rows() {
  if [ -f "$MANIFEST" ]; then
    grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$' || true
  fi
}

[ -f "$MANIFEST" ] || { echo "ERROR: no profiles yet — run ./setup.sh first."; exit 1; }
PROFILE_COUNT="$(rows | awk 'END{print NR+0}')"
[ "$PROFILE_COUNT" -ge 1 ] || { echo "ERROR: no profiles in $MANIFEST — run ./setup.sh add <name>."; exit 1; }

# --- read Terraform outputs (the box must already be applied) ---
ID="$(terraform output -raw instance_id 2>/dev/null || true)"
case "$ID" in
  i-*) : ;;
  *) echo "ERROR: no instance in Terraform state. Run './setup.sh && terraform apply' first."; exit 1 ;;
esac
DNS_NAME="$(terraform output -raw dns_name)"
PARAM="$(terraform output -raw server_pubkey_param)"
READY_PARAM="$(terraform output -raw ready_param)"
PSK_ARN="$(terraform output -raw preshared_key_secret_arn)"

# --- start it ---
echo ">> starting $ID"
aws ec2 start-instances --region "$REGION" --instance-ids "$ID" >/dev/null
aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"

PUBIP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
{ [ -n "$PUBIP" ] && [ "$PUBIP" != "None" ]; } || { echo "ERROR: instance has no public IP"; exit 1; }
echo ">> instance public IP: $PUBIP"

# --- has THIS instance finished its boot setup? ---
# On a plain restart user-data doesn't re-run, so the parameter still holds this
# instance's id and the check passes immediately. It only waits after a rebuild — and
# it catches a box whose user-data died, which the server-public-key parameter cannot:
# that one survives instance replacement, so a dead box inherits a valid-looking key
# and you end up with a tunnel that connects and carries nothing.
echo ">> waiting for $ID to finish its boot setup"
READY=""
for _ in $(seq 1 100); do
  READY="$(aws ssm get-parameter --region "$REGION" --name "$READY_PARAM" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  [ "$READY" = "$ID" ] && break
  sleep 3
done
if [ "$READY" != "$ID" ]; then
  echo
  echo "ERROR: $ID never reported ready (parameter holds '${READY}')."
  echo "       Its user-data failed, so WireGuard is probably not installed. Check:"
  echo "         aws ssm start-session --target $ID"
  echo "         sudo tail -50 /var/log/cloud-init-output.log"
  echo "       No client configs were rendered — a config written now would connect to"
  echo "       a box that can't carry traffic."
  exit 1
fi

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

# --- which configs are missing? (they're stable across sessions, so only render once) ---
wants_mode() { # profile-mode, wanted-mode
  case "$1" in "$2"|both) return 0 ;; *) return 1 ;; esac
}

MISSING=0
while IFS=$'\t' read -r n s m p; do
  for mm in split full; do
    if wants_mode "$m" "$mm" && [ ! -f "$CLIENT_DIR/$n/wg-$n-$mm.conf" ]; then MISSING=1; fi
  done
done < <(rows)

if [ "$MISSING" -eq 1 ]; then
  echo ">> reading the server public key"
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

  while IFS=$'\t' read -r n s m p; do
    dir="$CLIENT_DIR/$n"
    key="$dir/private.key"
    # No private key => a bring-your-own-key peer (or a deleted key). Either way we
    # can't render a config for it; the peer itself is still served by the server.
    if [ ! -f "$key" ]; then
      echo ">> skipping '$n': no $key (bring-your-own-key profile, or the key was deleted)"
      continue
    fi
    CLIENT_PRIV="$(cat "$key")"
    for mm in split full; do
      wants_mode "$m" "$mm" || continue
      conf="$dir/wg-$n-$mm.conf"
      [ -f "$conf" ] && continue
      if [ "$mm" = "full" ]; then
        ALLOWED="0.0.0.0/0, ::/0"; DNSLINE="DNS = ${CLIENT_DNS}"
      else
        ALLOWED="${WG_NET}.0/24"; DNSLINE=""
      fi
      ( umask 077; cat > "$conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_NET}.${s}/32
${DNSLINE}
[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${DNS_NAME}:${WG_PORT}
AllowedIPs = ${ALLOWED}
PersistentKeepalive = 25
EOF
)
      echo ">> wrote $conf"
    done
  done < <(rows)
  unset CLIENT_PRIV PSK
fi

# --- (re)generate the PAC from domains.txt each run so edits take effect ---
# The PAC is a macOS client-side setting, so there's one shared file rather than one
# per profile: it only applies to the Mac it's configured on. Split-mode profiles on
# other machines need the same PAC set up there (see install-pac-server.sh).
if rows | awk -F'\t' '$3=="split" || $3=="both"{f=1} END{exit !f}'; then
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

echo
echo "VPN UP.  ${DNS_NAME}:${WG_PORT} -> ${PUBIP}"
echo
printf '%-16s %-12s %s\n' "PROFILE" "TUNNEL IP" "CONFIG"
while IFS=$'\t' read -r n s m p; do
  shown=0
  for mm in split full; do
    wants_mode "$m" "$mm" || continue
    conf="$CLIENT_DIR/$n/wg-$n-$mm.conf"
    if [ -f "$conf" ]; then
      printf '%-16s %-12s %s\n' "$n" "${WG_NET}.${s}" "$conf"
      shown=1
    fi
  done
  if [ "$shown" -eq 0 ]; then
    printf '%-16s %-12s %s\n' "$n" "${WG_NET}.${s}" "(no local config — peer served, key held elsewhere)"
  fi
done < <(rows)
echo
echo "Import a config into WireGuard once; it stays valid across sessions."
echo "Handing one to someone else?  ./setup.sh qr <profile>   (scannable from the phone app)"
echo "Every profile has its own key, so they can all be connected at the same time."
echo "Done?  ./down.sh"
