#!/usr/bin/env bash
set -uo pipefail

VNC_USER="${VNC_USER:-vnc}"
VNC_USER_PASSWORD="${VNC_USER_PASSWORD:-123v1n}"
VNC_PASSWORD="${VNC_PASSWORD:-123v1n}"   # max 8 chars

sudo sysadminctl -addUser "$VNC_USER" -fullName "VNC User" \
  -password "$VNC_USER_PASSWORD" -admin
sudo pmset -a displaysleep 0 sleep 0 disablesleep 1 || true
nohup caffeinate -dimsu > /dev/null 2>&1 &

# ---- diagnostics: this is the important part ----
echo "== macOS: $(sw_vers -productVersion) arch: $(uname -m)"
echo "== SIP: $(csrutil status 2>&1 | head -1)"
echo "== console user: $(stat -f%Su /dev/console)"
echo "== displays:"; system_profiler SPDisplaysDataType | grep -E "Resolution|Display Type|Online|Main Display" || echo "(none reported)"
screencapture -x /tmp/shot.png 2>&1; ls -l /tmp/shot.png 2>&1
sips -g pixelWidth -g pixelHeight /tmp/shot.png 2>&1 | tail -2

# ---- TCC (best effort; read the output, it tells you if it was refused) ----
DB="/Library/Application Support/com.apple.TCC/TCC.db"
NOW=$(date +%s)
for SVC in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServicePostEvent kTCCServiceListenEvent; do
  for CLIENT in com.apple.screensharing.agent com.apple.ARDAgent com.apple.RemoteDesktopAgent; do
    sudo sqlite3 "$DB" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,flags,last_modified) VALUES ('$SVC','$CLIENT',0,2,4,1,0,$NOW);" 2>&1 | head -1
  done
done
echo "== TCC rows now:"; sudo sqlite3 "$DB" "select service,client,auth_value from access where client like 'com.apple.%agent%' or client like '%ARD%';" 2>&1 | head -12

# ---- Screen Sharing ----
K=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart
sudo "$K" -activate -configure -access -on \
  -clientopts -setvnclegacy -vnclegacy yes \
  -clientopts -setvncpw -vncpw "$VNC_PASSWORD" \
  -restart -agent -privs -all
sudo launchctl enable system/com.apple.screensharing || true
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
sleep 3
nc -z localhost 5900 && echo "VNC listening on 5900" || echo "VNC NOT listening"

# ---- noVNC (no resize hacks) ----
brew install cloudflared
git clone --depth 1 --branch v1.5.0 https://github.com/novnc/noVNC.git "$HOME/noVNC"
printf '{"resize":"scale","show_dot":true}' > "$HOME/noVNC/defaults.json"
python3 -m venv "$HOME/wsvenv"
"$HOME/wsvenv/bin/pip" install --quiet websockify

start_ws() {
  nohup "$HOME/wsvenv/bin/websockify" --web "$HOME/noVNC" 6080 localhost:5900 >> ws.log 2>&1 &
}
start_ws; sleep 2
nc -z localhost 6080 && echo "websockify listening on 6080" || { cat ws.log; exit 1; }

URL=""
start_tunnel() {
  pkill -x cloudflared 2>/dev/null || true
  : > cf.log
  nohup cloudflared tunnel --no-autoupdate --protocol http2 --edge-ip-version 4 \
    --url http://localhost:6080 > cf.log 2>&1 &
  URL=""
  for _ in $(seq 1 40); do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cf.log | head -1 || true)
    [ -n "$URL" ] && break; sleep 2
  done
  [ -z "$URL" ] && { echo "Tunnel did not start:"; cat cf.log; return 1; }
  echo "## VNC ready ($(date +%H:%M:%S))"
  echo "Open: $URL/vnc.html?autoconnect=1&resize=scale&show_dot=1"
  echo "Login: $VNC_USER / $VNC_USER_PASSWORD   (or VNC password: $VNC_PASSWORD)"
}

start_tunnel || true
END=$(( $(date +%s) + 19800 )); TICK=0
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 10; TICK=$((TICK+1))
  if ! pgrep -x cloudflared > /dev/null; then
    echo "cloudflared died. last log lines:"; tail -15 cf.log
    echo "restarting, NEW URL below:"
    start_tunnel || true
  fi
  pgrep -f websockify > /dev/null || { echo "websockify died:"; tail -10 ws.log; start_ws; }
  [ $((TICK % 6)) -eq 0 ] && echo "[still up] $URL/vnc.html?autoconnect=1&resize=scale&show_dot=1"
done
