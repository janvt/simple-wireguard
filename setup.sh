#!/usr/bin/env bash
#
# setup.sh — one-time bootstrap, plus profile management.
#
#   ./setup.sh [hostname]          # init: record hostname, create/migrate the first profile
#   ./setup.sh add <name> [mode]   # add a profile   (mode: split | full | both — default both)
#   ./setup.sh rm  <name>          # remove a profile
#   ./setup.sh list                # show profiles
#   ./setup.sh qr  <name> [mode]   # print a profile's config as a QR code (for phones)
#
# Each profile is a WireGuard peer with its OWN key pair and its own tunnel IP, so
# several devices/people can be connected at the same time. Private keys are
# generated here and never leave this Mac except inside the .conf you hand out.
#
# State lives in client/profiles.tsv (git-ignored), one private key per profile in
# client/<name>/private.key. setup.sh renders the PUBLIC half of that list into
# terraform.tfvars; `terraform apply` publishes it to an SSM parameter; the instance
# syncs its peer list from SSM at boot and every couple of minutes — so adding a
# profile never rebuilds the box.
#
set -euo pipefail
cd "$(dirname "$0")"

CLIENT_DIR="client"
MANIFEST="$CLIENT_DIR/profiles.tsv"
LEGACY_KEY="$CLIENT_DIR/client.key"

mkdir -p "$CLIENT_DIR"; chmod 700 "$CLIENT_DIR"

# --- key generation (wireguard-tools if present, else openssl@3) ---------------
have_wg() { command -v wg >/dev/null 2>&1; }
OSSL="openssl"
if ! have_wg; then
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

# --- manifest helpers ----------------------------------------------------------
# Format: name <TAB> ip_suffix <TAB> mode <TAB> public_key
manifest_init() {
  if [ ! -f "$MANIFEST" ]; then
    ( umask 077; printf '# name\tsuffix\tmode\tpublic_key\n' > "$MANIFEST" )
  fi
}

rows() {
  if [ -f "$MANIFEST" ]; then
    grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$' || true
  fi
}

has_profile() { rows | awk -F'\t' -v n="$1" '$1==n{f=1} END{exit !f}'; }

# Suffix .1 is the server, so peers start at .2. Never reuses a freed suffix, which
# keeps handed-out configs unambiguous.
next_suffix() { rows | awk -F'\t' 'BEGIN{m=1} $2>m{m=$2} END{print m+1}'; }

field_of() { rows | awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c; exit}'; }

check_name() {
  case "$1" in
    ''|*[!a-zA-Z0-9-]*) echo "ERROR: profile name must be letters, digits and dashes only"; exit 1 ;;
  esac
}

check_mode() {
  case "$1" in
    split|full|both) : ;;
    *) echo "ERROR: mode must be 'split', 'full' or 'both'"; exit 1 ;;
  esac
}

# --- terraform.tfvars is rendered from the manifest every time it changes -------
render_tfvars() {
  local dns prefix
  dns="$(sed -nE 's/^dns_name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform.tfvars 2>/dev/null || true)"
  [ -n "${1:-}" ] && dns="$1"
  [ -n "$dns" ] || { echo "ERROR: no dns_name recorded — run ./setup.sh <hostname> first"; exit 1; }
  # Preserve a pinned resource-name prefix so an existing deployment keeps its names.
  prefix="$(sed -nE 's/^name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform.tfvars 2>/dev/null || true)"

  {
    echo "dns_name = \"${dns}\""
    [ -n "$prefix" ] && echo "name     = \"${prefix}\""
    echo "peers = {"
    rows | while IFS=$'\t' read -r n s _m p; do
      printf '  "%s" = { public_key = "%s", ip_suffix = %s }\n' "$n" "$p" "$s"
    done
    echo "}"
  } > terraform.tfvars

  cat > dns/terraform.tfvars <<EOF
dns_name = "${dns}"
EOF
}

# --- commands ------------------------------------------------------------------
add_profile() {
  local name="$1" mode="${2:-both}" dir key pub
  check_name "$name"; check_mode "$mode"
  manifest_init
  if has_profile "$name"; then
    echo ">> profile '$name' already exists (10.8.0.$(field_of "$name" 2), mode $(field_of "$name" 3))"
    return 0
  fi
  dir="$CLIENT_DIR/$name"; key="$dir/private.key"
  mkdir -p "$dir"; chmod 700 "$dir"
  if [ ! -f "$key" ]; then
    echo ">> generating key for '$name'"
    ( umask 077; gen_priv > "$key" || true )
  fi
  if [ ! -s "$key" ]; then
    rm -f "$key"
    echo "ERROR: key generation failed. Install wireguard-tools (brew install wireguard-tools)"
    echo "       or openssl@3 (brew install openssl@3) — macOS's built-in LibreSSL cannot do X25519."
    exit 1
  fi
  pub="$(pub_of "$(cat "$key")" || true)"
  [ -n "$pub" ] || { echo "ERROR: could not derive public key for '$name'. Install wireguard-tools or openssl@3."; exit 1; }
  printf '%s\t%s\t%s\t%s\n' "$name" "$(next_suffix)" "$mode" "$pub" >> "$MANIFEST"
  echo ">> added profile '$name' at 10.8.0.$(field_of "$name" 2) (mode: $mode)"
}

rm_profile() {
  local name="$1" tmp
  has_profile "$name" || { echo "ERROR: no profile named '$name'"; exit 1; }
  echo ">> removing profile '$name' (10.8.0.$(field_of "$name" 2))"
  echo "   this deletes $CLIENT_DIR/$name/ — its private key and rendered configs"
  tmp="$(mktemp)"
  awk -F'\t' -v n="$name" '/^[[:space:]]*#/ || $1!=n' "$MANIFEST" > "$tmp"
  ( umask 077; cat "$tmp" > "$MANIFEST" ); rm -f "$tmp"
  rm -rf "${CLIENT_DIR:?}/${name:?}"
  echo ">> removed. Run 'terraform apply' to revoke it on the server."
}

list_profiles() {
  if [ -z "$(rows)" ]; then echo "No profiles yet — run ./setup.sh add <name>"; return 0; fi
  printf '%-16s %-12s %-7s %s\n' "PROFILE" "TUNNEL IP" "MODE" "CONFIGS"
  rows | while IFS=$'\t' read -r n s m _p; do
    local confs=""
    for mm in split full; do
      case "$m" in "$mm"|both) confs="${confs:+$confs, }$CLIENT_DIR/$n/wg-$n-$mm.conf" ;; esac
    done
    printf '%-16s %-12s %-7s %s\n' "$n" "10.8.0.$s" "$m" "${confs:-–}"
  done
}

show_qr() {
  local name="$1" mode="${2:-}" conf
  has_profile "$name" || { echo "ERROR: no profile named '$name'"; exit 1; }
  if [ -z "$mode" ]; then
    mode="$(field_of "$name" 3)"
    if [ "$mode" = both ]; then mode=full; fi
  fi
  conf="$CLIENT_DIR/$name/wg-$name-$mode.conf"
  [ -f "$conf" ] || { echo "ERROR: $conf not rendered yet — run ./up.sh first"; exit 1; }
  command -v qrencode >/dev/null 2>&1 || { echo "ERROR: qrencode not installed (brew install qrencode)"; exit 1; }
  echo ">> $conf — scan from the WireGuard app (Add tunnel > Create from QR code)"
  qrencode -t ansiutf8 < "$conf"
}

# Pull a pre-profiles client/client.key into the manifest at 10.8.0.2, so an
# already-imported tunnel keeps working untouched (same key, same IP).
migrate_legacy() {
  if [ ! -f "$LEGACY_KEY" ]; then return 0; fi
  if [ -n "$(rows)" ]; then return 0; fi
  local name="${LEGACY_PROFILE_NAME:-mac}" pub
  pub="$(pub_of "$(cat "$LEGACY_KEY")" || true)"
  [ -n "$pub" ] || { echo "ERROR: could not derive a public key from $LEGACY_KEY (empty or corrupt?)"; exit 1; }
  mkdir -p "$CLIENT_DIR/$name"; chmod 700 "$CLIENT_DIR/$name"
  cp "$LEGACY_KEY" "$CLIENT_DIR/$name/private.key"; chmod 600 "$CLIENT_DIR/$name/private.key"
  manifest_init
  printf '%s\t2\tboth\t%s\n' "$name" "$pub" >> "$MANIFEST"
  echo ">> migrated your existing client key into profile '$name' at 10.8.0.2"
  echo "   (same key, same IP — tunnels you already imported keep working)"
}

cmd_init() {
  local dns="${1:-}"
  if [ -z "$dns" ] && [ -f terraform.tfvars ]; then
    dns="$(sed -nE 's/^dns_name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform.tfvars)"
  fi
  if [ -z "$dns" ]; then
    read -r -p "VPN hostname (e.g. vpn.example.com): " dns
  fi
  [ -n "$dns" ] || { echo "ERROR: a DNS name is required"; exit 1; }

  migrate_legacy
  if [ -z "$(rows)" ]; then add_profile "${DEFAULT_PROFILE:-mac}" both; fi
  render_tfvars "$dns"
  echo ">> wrote terraform.tfvars and dns/terraform.tfvars (dns_name=${dns})"
  echo
  list_profiles
  echo
  echo ">> next:  (cd dns && terraform init && terraform apply)   # once; then delegate NS"
  echo ">>        terraform init && terraform apply                # build/refresh the box"
  echo ">>        ./up.sh"
}

case "${1:-}" in
  add)  shift; [ $# -ge 1 ] || { echo "usage: ./setup.sh add <name> [split|full|both]"; exit 1; }
        add_profile "$1" "${2:-both}"; render_tfvars
        echo ">> run 'terraform apply' then './up.sh' to render the config" ;;
  rm|remove) shift; [ $# -ge 1 ] || { echo "usage: ./setup.sh rm <name>"; exit 1; }
        rm_profile "$1"; render_tfvars ;;
  list|ls) list_profiles ;;
  qr)   shift; [ $# -ge 1 ] || { echo "usage: ./setup.sh qr <name> [split|full]"; exit 1; }
        show_qr "$1" "${2:-}" ;;
  init) shift; cmd_init "${1:-}" ;;
  -h|--help|help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)    cmd_init "${1:-}" ;;
esac
