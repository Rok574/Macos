#!/usr/bin/env bash
set -uo pipefail

VNC_USER="${VNC_USER:-vnc}"
VNC_USER_PASSWORD="${VNC_USER_PASSWORD:-123v1n}"
VNC_PASSWORD="${VNC_PASSWORD:-123v1n}"   # legacy VNC password, max 8 chars

# ---- user ----
sudo sysadminctl -addUser "$VNC_USER" -fullName "VNC User" \
  -password "$VNC_USER_PASSWORD" -admin

# ---- keep display awake ----
sudo pmset -a displaysleep 0 sleep 0 disablesleep 1 || true
nohup caffeinate -dimsu > /dev/null 2>&1 &

# ---- diagnostics ----
echo "== macOS: $(sw_vers -productVersion) arch: $(uname -m)"
echo "== SIP: $(csrutil status 2>&1 | head -1)"
echo "== console user: $(stat -f%Su /dev/console)"

# ---- grant Screen Recording / Accessibility to the screen sharing agents ----
grant_tcc() {
  local DB="$1"
  [ -f "$DB" ] || return 0
  local NOW; NOW=$(date +%s)
  for SVC in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceListenEvent; do
    for CLIENT in com.apple.screensharing.agent com.apple.ARDAgent com.apple.RemoteDesktopAgent; do
      sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access \
        (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) \
        VALUES ('$SVC','$CLIENT',0,2,4,1,0,$NOW);" 2>&1 | head -1 || true
    done
  done
}
grant_tcc "/Library/Application Support/com.apple.TCC/TCC.db"
sudo killall tccd 2>/dev/null || true

# ---- enable Screen Sharing + legacy VNC password ----
K=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
sudo "$K" -activate -configure -access -on \
  -clientopts -setvnclegacy -vnclegacy yes \
  -clientopts -setvncpw -vncpw "$VNC_PASSWORD" \
  -restart -agent -privs -all
sudo launchctl enable system/com.apple.screensharing || true
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
sleep 3
nc -z localhost 5900 && echo "VNC listening on 5900"

# ---- tools ----
brew install cloudflared
git clone --depth 1 --branch v1.5.0 https://github.com/novnc/noVNC.git "$HOME/noVNC"
python3 -m venv "$HOME/wsvenv"
"$HOME/wsvenv/bin/pip" install --quiet websockify

nohup "$HOME/wsvenv/bin/websockify" --web "$HOME/noVNC" 6080 localhost:5900 > ws.log 2>&1 &
sleep 2
nc -z localhost 6080 && echo "websockify listening on 6080" || { cat ws.log; exit 1; }

# ---- tunnel with watchdog (http2 is far more stable than QUIC on runners) ----
start_tunnel() {
  pkill -x cloudflared 2>/dev/null || true
  : > cf.log
  nohup cloudflared tunnel --no-autoupdate --protocol http2 --edge-ip-version 4 \
    --url http://localhost:6080 > cf.log 2>&1 &
  local URL=""
  for _ in $(seq 1 40); do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cf.log | head -1 || true)
    [ -n "$URL" ] && break; sleep 2
  done
  if [ -z "$URL" ]; then echo "Tunnel did not start:"; cat cf.log; return 1; fi
  {
    echo "## VNC ready ($(date +%H:%M:%S))"
    echo "Open: $URL/vnc.html?autoconnect=1"
    echo "Login: $VNC_USER / $VNC_USER_PASSWORD   (or VNC password: $VNC_PASSWORD)"
  } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

start_tunnel || true
END=$(( $(date +%s) + 19800 ))
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 10
  if ! pgrep -x cloudflared > /dev/null; then
    echo "cloudflared died, restarting (new URL below)..."
    start_tunnel || true
  fi
  pgrep -f websockify > /dev/null || {
    nohup "$HOME/wsvenv/bin/websockify" --web "$HOME/noVNC" 6080 localhost:5900 > ws.log 2>&1 &
  }
done
