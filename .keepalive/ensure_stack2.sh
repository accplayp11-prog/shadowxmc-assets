#!/bin/bash
# Keeps Node 2 (wings on ominous-palm-tree) alive. Runs as codespace user (sudo passwordless).
set -u
DIR=/workspaces/tests/.keepalive
WINGS_BIN=/home/codespace/pterodactyl-lab/wings/wings
WINGS_CFG=/home/codespace/pterodactyl-lab/wings/config.yml
CF=$DIR/cloudflared
DAEMON_TOKEN=VMftKkdvpo4uj5XbaDTswQn1yGeYW7Og8xAEJ2Z3BFSPIl9RCNir0UhcmqHzL6
PANEL_API_KEY=ptla_YnOo2CjxwwHELTDRWg4unx9oRaXxsXVuhWqcBnnNpSf
TEST_SERVER=0879681e-3560-44fe-8cdd-c7e3f9c880b2
REPO_PANEL_FILE=https://raw.githubusercontent.com/itsindex/tests/main/.keepalive/panel-address.txt
APIPORT=$(sudo grep -A4 '^api:' "$WINGS_CFG" | sed -n 's/^  port: *//p' | head -1)
APIPORT=${APIPORT:-8082}

if ! pgrep -f "wings --config" >/dev/null 2>&1; then
  sudo nohup "$WINGS_BIN" --config "$WINGS_CFG" >>"$DIR/wings2.log" 2>&1 &
  sleep 12
fi

if ! sudo docker ps --format "{{.Names}}" | grep -q "^${TEST_SERVER}$"; then
  curl -s -X POST -H "Authorization: Bearer $DAEMON_TOKEN" -H "Content-Type: application/json" \
    -d '{"action":"start"}' "http://127.0.0.1:$APIPORT/api/servers/$TEST_SERVER/power" >/dev/null 2>&1 || true
fi

PANEL=$(curl -s "$REPO_PANEL_FILE" | tr -d '[:space:]')
if [ -x "$CF" ]; then
  if ! pgrep -f "cloudflared tunnel --url http://127.0.0.1:$APIPORT" >/dev/null 2>&1; then
    sudo nohup "$CF" tunnel --url http://127.0.0.1:$APIPORT --no-autoupdate >"$DIR/wings-tunnel.log" 2>&1 &
    sleep 12
  fi
  HOST=$(sudo grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" "$DIR/wings-tunnel.log" 2>/dev/null | head -1)
  if [ -n "$HOST" ]; then
    echo "$HOST" > "$DIR/wings-hostname.txt"
    if [ -n "$PANEL" ]; then
      curl -s -X PATCH -H "Authorization: Bearer $PANEL_API_KEY" \
        -H "Accept: application/vnd.pterodactyl.v1+json" -H "Content-Type: application/json" \
        -d "{\"name\":\"Codespace Node 2\",\"description\":null,\"location_id\":1,\"fqdn\":\"$HOST\",\"scheme\":\"https\",\"behind_proxy\":true,\"maintenance_mode\":false,\"memory\":16384,\"memory_overallocate\":0,\"disk\":30720,\"disk_overallocate\":0,\"upload_size\":100,\"daemon_listen\":443,\"daemon_sftp\":2023,\"daemon_base\":\"/var/lib/pterodactyl/volumes\"}" \
        "$PANEL/api/application/nodes/2" >/dev/null 2>&1 || true
    fi
  fi
fi

if [ -n "$PANEL" ]; then
  if ! sudo grep -q "remote: $PANEL" "$WINGS_CFG" 2>/dev/null; then
    sudo cp "$WINGS_CFG" "$WINGS_CFG.bak"
    sudo sed -i "s|^remote: .*|remote: $PANEL|" "$WINGS_CFG"
    sudo python3 - "/home/codespace/pterodactyl-lab/wings/config.yml" "$PANEL" <<'PY'
import sys
p,h=sys.argv[1],sys.argv[2]
lines=open(p).read().split("\n")
out=[]; in_block=False; entries=[]
for ln in lines:
    if in_block:
        if ln.strip()=="" or (ln and ln[0] not in " -"):
            in_block=False
            out.append("allowed_origins:")
            if h not in entries: entries.append(h)
            for e in entries: out.append("  - %s" % e)
            out.append(ln)
            continue
        if ln.strip().startswith("- "):
            e=ln.strip()[2:].strip()
            if e not in entries: entries.append(e)
            continue
        continue
    if ln.strip()=="allowed_origins:":
        in_block=True; continue
    out.append(ln)
open(p,"w").write("\n".join(out))
PY
    sudo pkill -f "wings --config"
    sleep 3
    sudo nohup "$WINGS_BIN" --config "$WINGS_CFG" >>"$DIR/wings2.log" 2>&1 &
    sleep 8
  fi
fi

if ! pgrep -f "keep_node2_alive.sh" >/dev/null 2>&1; then
  sudo setsid bash -c 'exec /workspaces/tests/.keepalive/keep_node2_alive.sh >>/tmp/keepalive2.log 2>&1' </dev/null >/dev/null 2>&1 &
fi

echo "node2 stack ok"
