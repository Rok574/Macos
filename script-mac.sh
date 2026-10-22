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
brew install cloudflared displayplacer
NOVNC="$HOME/noVNC"
git clone --depth 1 --branch v1.5.0 https://github.com/novnc/noVNC.git "$NOVNC"
python3 -m venv "$HOME/wsvenv"
"$HOME/wsvenv/bin/pip" install --quiet websockify

# ---- noVNC defaults: cursor dot + client-side scaling as fallback ----
cat > "$NOVNC/defaults.json" <<'EOF'
{
  "resize": "scale",
  "show_dot": true,
  "view_clip": false
}
EOF

# ---- browser side: report window size to /resize (debounced) ----
cat > "$NOVNC/autoresize.js" <<'EOF'
(function () {
  var timer = null, last = "";
  function send() {
    if (document.hidden) return;
    var w = Math.max(640, Math.round(window.innerWidth));
    var h = Math.max(480, Math.round(window.innerHeight));
    var key = w + "x" + h;
    if (key === last) return;
    last = key;
    fetch("/resize?w=" + w + "&h=" + h, { cache: "no-store" }).catch(function () {});
  }
  function schedule(ms) { clearTimeout(timer); timer = setTimeout(send, ms); }
  window.addEventListener("resize", function () { schedule(700); });
  window.addEventListener("load", function () { schedule(3000); });
  document.addEventListener("visibilitychange", function () { schedule(500); });
})();
EOF
sed -i '' 's#</body>#<script src="autoresize.js"></script></body>#' "$NOVNC/vnc.html"
grep -q autoresize.js "$NOVNC/vnc.html" && echo "autoresize.js injected"

# ---- server: noVNC static + VNC websocket proxy + /resize endpoint ----
cat > "$HOME/vnc_server.py" <<'EOF'
#!/usr/bin/env python3
import os, re, subprocess, threading
from urllib.parse import urlparse, parse_qs
from websockify.websocketproxy import WebSocketProxy, ProxyRequestHandler

NOVNC = os.path.expanduser("~/noVNC")
MODE_RE = re.compile(r"mode (\d+): res:(\d+)x(\d+) hz:(\d+) color_depth:(\d+)")
lock = threading.Lock()
state = {"last": None}

def apply_resize(W, H):
    out = subprocess.run(["displayplacer", "list"], capture_output=True,
                         text=True, timeout=20).stdout
    m = re.search(r"Persistent screen id:\s*(\S+)", out)
    if not m:
        return "no display id found"
    sid = m.group(1)
    modes = [tuple(int(x) for x in t) for t in MODE_RE.findall(out)]
    # (mode, w, h, hz, depth)
    if not modes:
        res = f"{W}x{H}"
        arg = f"id:{sid} res:{res} hz:60 color_depth:8 scaling:off"
    else:
        fit = [x for x in modes if x[1] <= W and x[2] <= H]
        if fit:
            best = max(fit, key=lambda x: (x[1] * x[2], x[3] == 60, x[4] == 8, x[3]))
        else:
            best = min(modes, key=lambda x: x[1] * x[2])
        if state["last"] == best[:3]:
            return f"already {best[1]}x{best[2]}"
        state["last"] = best[:3]
        arg = f"id:{sid} mode:{best[0]}"
    r = subprocess.run(["displayplacer", arg], capture_output=True, text=True, timeout=30)
    return f"{arg} -> rc={r.returncode} {r.stderr.strip()[:200]}"

class Handler(ProxyRequestHandler):
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/resize":
            q = parse_qs(u.query)
            try:
                W = max(640, min(int(q["w"][0]), 3840))
                H = max(480, min(int(q["h"][0]), 2160))
            except Exception:
                self.send_error(400, "bad size")
                return
            with lock:
                try:
                    msg = apply_resize(W, H)
                except Exception as e:
                    msg = f"error: {e}"
            print(f"[resize] {W}x{H}: {msg}", flush=True)
            body = msg.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

if __name__ == "__main__":
    WebSocketProxy(
        listen_host="127.0.0.1", listen_port=6080,
        target_host="127.0.0.1", target_port=5900,
        web=NOVNC, RequestHandlerClass=Handler,
    ).start_server()
EOF

start_server() {
  nohup "$HOME/wsvenv/bin/python" "$HOME/vnc_server.py" >> ws.log 2>&1 &
}
start_server
sleep 2
nc -z localhost 6080 && echo "noVNC server listening on 6080" || { cat ws.log; exit 1; }

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
    echo "Open: $URL/vnc.html?autoconnect=1&resize=scale&show_dot=1"
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
  pgrep -f vnc_server.py > /dev/null || start_server
done
