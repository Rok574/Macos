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

# Keyless cloudflared quick tunnel (TCP)
brew install cloudflared
nohup cloudflared tunnel --no-autoupdate --url tcp://localhost:5900 > cf.log 2>&1 &

HOST=""
for _ in $(seq 1 30); do
  HOST=$(grep -oE '[a-z0-9-]+\.trycloudflare\.com' cf.log | head -1 || true)
  [ -n "$HOST" ] && break; sleep 2
done
[ -z "$HOST" ] && { cat cf.log; echo "Tunnel failed"; exit 1; }

{
  echo "## VNC ready"
  echo "On your machine, run:"
  echo '```'
  echo "cloudflared access tcp --hostname $HOST --url localhost:5900"
  echo '```'
  echo "Then connect Screen Sharing / any VNC client to localhost:5900"
  echo "Apple Screen Sharing login: $VNC_USER / $VNC_USER_PASSWORD"
  echo "Other VNC clients password: $VNC_PASSWORD"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
