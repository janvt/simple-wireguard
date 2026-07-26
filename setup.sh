#!/usr/bin/env bash
#
# setup.sh — run ONCE before your first `terraform apply`.
# Generates the client key and writes your real hostname + client public key into
# terraform.tfvars (and dns/terraform.tfvars) — both git-ignored, so your domain
# never ships in the repo. The committed defaults are placeholders (vpn.example.com).
#
# Usage:  ./setup.sh [vpn.your-domain.tld]   (prompts if omitted)
#
set -euo pipefail
cd "$(dirname "$0")"

CLIENT_DIR="client"
CLIENT_KEY="$CLIENT_DIR/client.key"
mkdir -p "$CLIENT_DIR"; chmod 700 "$CLIENT_DIR"

# --- capture the VPN hostname (arg > existing tfvars > prompt) ---
DNS_NAME="${1:-}"
if [ -z "$DNS_NAME" ] && [ -f terraform.tfvars ]; then
  DNS_NAME="$(sed -nE 's/^dns_name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform.tfvars)"
fi
if [ -z "$DNS_NAME" ]; then
  read -r -p "VPN hostname (e.g. vpn.example.com): " DNS_NAME
fi
[ -n "$DNS_NAME" ] || { echo "ERROR: a DNS name is required"; exit 1; }

# Preserve a pinned resource-name prefix if the tfvars already has one (keeps an
# existing deployment's resource names stable across setup re-runs).
NAME_PREFIX="$(sed -nE 's/^name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform.tfvars 2>/dev/null || true)"

have_wg() { command -v wg >/dev/null 2>&1; }
if ! have_wg; then
  OSSL="openssl"
  for c in "$(brew --prefix openssl@3 2>/dev/null)/bin/openssl" /opt/homebrew/opt/openssl@3/bin/openssl; do
    [ -x "$c" ] && { OSSL="$c"; break; }
  done
fi
gen_priv() {
  if have_wg; then wg genkey
  else "$OSSL" genpkey -algorithm X25519 -outform DER 2>/dev/null | tail -c 32 | base64; fi
}
pub_of() {
  if have_wg; then printf '%s' "$1" | wg pubkey
  else { printf '302e020100300506032b656e04220420' | xxd -r -p; printf '%s' "$1" | base64 -d; } \
       | "$OSSL" pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64; fi
}

if [ ! -f "$CLIENT_KEY" ]; then
  echo ">> generating client key"
  ( umask 077; gen_priv > "$CLIENT_KEY" )
fi
CLIENT_PUB="$(pub_of "$(cat "$CLIENT_KEY")")"
[ -n "$CLIENT_PUB" ] || { echo "ERROR: could not derive client public key. Install wireguard-tools or openssl@3."; exit 1; }

{
  echo "client_public_key = \"${CLIENT_PUB}\""
  echo "dns_name          = \"${DNS_NAME}\""
  [ -n "$NAME_PREFIX" ] && echo "name              = \"${NAME_PREFIX}\""
} > terraform.tfvars

# The dns/ config is a separate state and needs the hostname too.
cat > dns/terraform.tfvars <<EOF
dns_name = "${DNS_NAME}"
EOF

echo ">> wrote terraform.tfvars and dns/terraform.tfvars (dns_name=${DNS_NAME})"
echo ">> next:  (cd dns && terraform init && terraform apply)   # then delegate NS at your DNS host"
echo ">>        terraform init && terraform apply                # build the box"
echo ">>        ./up.sh"
