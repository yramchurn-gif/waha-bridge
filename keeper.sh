#!/bin/zsh
# WhatsApp bridge keeper — runs every 2 min via LaunchAgent.
# Ensures: WAHA container up, tunnel alive AND reachable from the internet,
# and the GitHub pointer (url.json) matching the real tunnel URL.
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
REPO="$HOME/My Stuffs/Claude/waha-bridge"
LOG="$REPO/cf-tunnel.log"
KEY="8702be4a78014055b28f2d81095ac177"

# 1. the container
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^waha$'; then
  docker start waha >/dev/null 2>&1
fi

# 2. current tunnel URL from the log of the cloudflared WE manage
url=""
if pgrep -f 'cloudflared tunnel .* --url http://localhost:3000' >/dev/null; then
  url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -1)
fi

# 3. health-check THROUGH the internet — a quick tunnel can die server-side
#    while the local process stays up (NXDOMAIN was exactly this failure).
healthy=0
if [ -n "$url" ]; then
  code=$(curl -s -m 12 -o /dev/null -w '%{http_code}' -H "X-Api-Key: $KEY" "$url/api/sessions" 2>/dev/null)
  [ "$code" = "200" ] && healthy=1
fi

# 4. restart the tunnel if dead or missing
if [ "$healthy" != "1" ]; then
  pkill -f 'cloudflared tunnel' 2>/dev/null; sleep 2
  : > "$LOG"
  nohup cloudflared tunnel --protocol http2 --url http://localhost:3000 >> "$LOG" 2>&1 &
  for i in {1..10}; do
    sleep 3
    url=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -1)
    [ -n "$url" ] && break
  done
  [ -z "$url" ] && exit 0   # no luck this round; next run retries
  sleep 3
fi

# 5. publish only on change
current=$(python3 -c "import json;print(json.load(open('$REPO/url.json'))['url'])" 2>/dev/null)
if [ "$url" != "$current" ] && [ -n "$url" ]; then
  python3 - "$url" <<PYEOF
import json,sys,datetime,socket
json.dump({"url":sys.argv[1],
           "updated":datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
           "host":socket.gethostname().split(".")[0]},
          open("$REPO/url.json","w"),indent=1)
PYEOF
  cd "$REPO" && git add url.json && git commit -q -m "tunnel rotated -> $url" && git push -q origin main
fi
