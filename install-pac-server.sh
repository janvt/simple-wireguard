#!/usr/bin/env bash
#
# install-pac-server.sh — (re)install the launchd agent that serves pac/ over
# http://127.0.0.1:<port>, so Safari's Automatic Proxy Configuration URL resolves.
# macOS silently ignores file:// PAC URLs, hence the tiny local http server.
#
# Idempotent. Re-run after moving the repo or if the server stops.
#
set -euo pipefail
cd "$(dirname "$0")"

REPO="$(pwd)"
PAC_DIR="$REPO/pac"
PORT="${PORT:-8899}"
LABEL="local.vpn-pac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Apple's /usr/bin/python3 is a stub that needs the CLT SDK and often fails under
# launchd (esp. when xcode-select points at full Xcode). Pick one that actually runs.
PY=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  [ -x "$c" ] && "$c" --version >/dev/null 2>&1 && { PY="$c"; break; }
done
if [ -z "$PY" ] && command -v python3 >/dev/null 2>&1; then
  cand="$(command -v python3)"; "$cand" --version >/dev/null 2>&1 && PY="$cand"
fi
[ -n "$PY" ] || { echo "ERROR: no working python3 found (try: brew install python3)"; exit 1; }

mkdir -p "$PAC_DIR"

# Retire any older personalised agent (e.g. dev.<name>.vpn-pac) to avoid a port clash.
for OLD in "$HOME/Library/LaunchAgents/dev."*".vpn-pac.plist"; do
  [ -e "$OLD" ] || continue
  launchctl bootout "gui/$(id -u)" "$OLD" 2>/dev/null || launchctl unload "$OLD" 2>/dev/null || true
  rm -f "$OLD"
done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>${PY}</string><string>-m</string><string>http.server</string>
    <string>${PORT}</string><string>--bind</string><string>127.0.0.1</string>
    <string>--directory</string><string>${PAC_DIR}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/vpn-pac.log</string>
  <key>StandardErrorPath</key><string>/tmp/vpn-pac.log</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
sleep 1

echo ">> python : $PY"
echo ">> serving: $PAC_DIR  ->  http://127.0.0.1:${PORT}/discovery.pac"
if curl -fsS "http://127.0.0.1:${PORT}/discovery.pac" >/dev/null 2>&1; then
  echo ">> OK — PAC is reachable."
else
  echo ">> NOT reachable yet — check /tmp/vpn-pac.log"
fi
echo ">> macOS PAC URL should be: http://127.0.0.1:${PORT}/discovery.pac"
echo "   (System Settings > Network > Wi-Fi > Details > Proxies > Automatic Proxy Configuration)"
