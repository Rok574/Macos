#!/usr/bin/env bash
set -euo pipefail

# Defaults (override with repo secrets if you want)
VNC_USER="${VNC_USER:-vnc}"
VNC_USER_PASSWORD="${VNC_USER_PASSWORD:-123v1n}"
VNC_PASSWORD="${VNC_PASSWORD:-123v1n}"   # legacy VNC password, max 8 chars

# New admin user (runner's password can't be reset: SecureToken)
sudo sysadminctl -addUser "$VNC_USER" -fullName "VNC User" \
  -password "$VNC_USER_PASSWORD" -admin

# Enable Screen Sharing + legacy VNC password
K=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
sudo "$K" -activate -configure -access -on \
  -clientopts -setvnclegacy -vnclegacy yes \
  -clientopts -setvncpw -vncpw "$VNC_PASSWORD" \
  -restart -agent -privs -all
sudo launchctl enable system/com.apple.screensharing || true
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
sleep 3
nc -z localhost 5900 && echo "VNC listening on 5900"

# cloudflared
brew install cloudflared

# noVNC (from GitHub) + websockify (from pip, in a venv)
git clone --depth 1 --branch v1.5.0 https://github.com/novnc/noVNC.git "$HOME/noVNC"
python3 -m venv "$HOME/wsvenv"
"$HOME/wsvenv/bin/pip" install --quiet websockify

nohup "$HOME/wsvenv/bin/websockify" --web "$HOME/noVNC" 6080 localhost:5900 > ws.log 2>&1 &
sleep 2
nc -z localhost 6080 && echo "websockify listening on 6080" || { cat ws.log; exit 1; }

# Keyless cloudflared quick tunnel (HTTP)
nohup cloudflared tunnel --no-autoupdate --url http://localhost:6080 > cf.log 2>&1 &

URL=""
for _ in $(seq 1 30); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cf.log | head -1 || true)
  [ -n "$URL" ] && break; sleep 2
done
[ -z "$URL" ] && { cat cf.log; echo "Tunnel failed"; exit 1; }

{
  echo "## VNC ready"
  echo "Open this in any browser (works on iPhone):"
  echo "$URL/vnc.html?autoconnect=1"
  echo "Password: $VNC_PASSWORD"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
