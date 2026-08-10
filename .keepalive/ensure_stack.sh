#!/bin/bash
# Keeps the GALAXYBOX stack alive. Runs as codespace user (sudo is passwordless).
# Called on every keep-alive ping from the PC bot.
set -u

STACK_DIR=/home/codespace/pterodactyl-lab
DIR=/workspaces/tests/.keepalive
PLAYIT_BIN=$DIR/playit-linux
PLAYIT_SECRET="568282af4a3ec84313971980662303e5c974b38dfb056a08164856c6f5f7003d"
SERVER_UUID=7dceaf6d-0c9d-4808-912c-5a96ff1b61b6
PANEL_OVERRIDES=$DIR/panel-overrides
PANEL_CONF=$DIR/panel.conf
WINGS_PROXY_SETUP=$DIR/wings-proxy/setup_wings_proxy.sh
IDLE_WATCH=$DIR/wings-proxy/idle_watch.sh
BORE_BIN=$DIR/bore
WINGS_CFG="$STACK_DIR/wings/config.yml"
COMPOSE="$STACK_DIR/docker-compose.yml"

# --- 1) Wings daemon ---
if ! pgrep -f "wings --config" >/dev/null 2>&1; then
  (cd "$STACK_DIR/wings" && sudo nohup ./wings --config config.yml >>/tmp/wings.log 2>&1 &)
  sleep 12
fi

# --- 2) playit agent ---
if ! pgrep -f "playit-linux" >/dev/null 2>&1; then
  sudo nohup "$PLAYIT_BIN" --secret "$PLAYIT_SECRET" -l /tmp/playit.log >/tmp/playit.out 2>&1 &
  sleep 6
fi

# --- 2b) bore tunnel (Paper server, 25566) ---
if [ -x "$BORE_BIN" ]; then
  if ! pgrep -f "bore local 25566" >/dev/null 2>&1; then
    sudo nohup "$BORE_BIN" local 25566 --to bore.pub --port 28886 >"$DIR/bore.log" 2>&1 &
    sleep 6
  fi
  echo "bore.pub:28886" > "$DIR/mc2-address.txt"
fi

# --- 3) GALAXYBOX server container (via Wings API) ---
if ! sudo docker ps --format "{{.Names}}" | grep -q "^${SERVER_UUID}$"; then
  TOKEN=$(sudo grep "^token:" "$STACK_DIR/wings/config.yml" 2>/dev/null | awk '{print $2}')
  if [ -n "$TOKEN" ]; then
    curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '{"action":"start"}' "http://127.0.0.1:8081/api/servers/$SERVER_UUID/power" >/dev/null 2>&1
  fi
fi


# --- 3c) DC bot server (Discord bot on node 1) ---
BOT_UUID=3ec446d7-fa8f-45e0-a122-b4788ef7fb77
if ! sudo docker ps --format "{{.Names}}" | grep -q "^${BOT_UUID}$"; then
  BTOKEN=$(sudo grep "^token:" "$STACK_DIR/wings/config.yml" 2>/dev/null | awk '{print $2}')
  if [ -n "$BTOKEN" ]; then
    curl -s -X POST -H "Authorization: Bearer $BTOKEN" -H "Content-Type: application/json" \
      -d '{"action":"start"}' "http://127.0.0.1:8081/api/servers/$BOT_UUID/power" >/dev/null 2>&1
  fi
fi

# --- 3b) wings TLS proxy (panel->wings internal routing) + idle watcher ---
if [ -x "$WINGS_PROXY_SETUP" ]; then
  sudo bash "$WINGS_PROXY_SETUP" >/tmp/wings-proxy-setup.log 2>&1 || true
fi
if [ -x "$IDLE_WATCH" ]; then
  if ! pgrep -f "idle_watch.sh" >/dev/null 2>&1; then
    sudo nohup bash "$IDLE_WATCH" >/tmp/idle_watch.log 2>&1 &
  fi
fi

# --- 4) panel overrides (TrustProxies fix + nginx config) ---
if sudo docker ps --format "{{.Names}}" | grep -q "^ptero-panel$"; then
  NEED_RESTART=0
  if ! sudo docker exec ptero-panel test -f /app/app/Http/Middleware/TrustProxies.php 2>/dev/null; then
    echo "restoring panel TrustProxies overrides"
    sudo docker cp "$PANEL_OVERRIDES/TrustProxies.php" ptero-panel:/app/app/Http/Middleware/TrustProxies.php
    sudo docker cp "$PANEL_OVERRIDES/Kernel.php" ptero-panel:/app/app/Http/Kernel.php
    sudo docker exec ptero-panel sh -c 'grep -q "use Pterodactyl\\\\Http\\\\Middleware\\\\TrustProxies;" /app/app/Http/Kernel.php || sed -i "s|use Illuminate\\\\Http\\\\Middleware\\\\TrustProxies;|use Pterodactyl\\\\Http\\\\Middleware\\\\TrustProxies;|" /app/app/Http/Kernel.php'
    NEED_RESTART=1
  fi
  if ! sudo docker exec -i ptero-panel cmp -s /etc/nginx/http.d/panel.conf - < "$PANEL_CONF" 2>/dev/null; then
    echo "restoring panel nginx config"
    sudo docker cp "$PANEL_CONF" ptero-panel:/etc/nginx/http.d/panel.conf
    NEED_RESTART=1
  fi
  if [ "$NEED_RESTART" = "1" ]; then
    sudo docker restart ptero-panel >/dev/null 2>&1
  fi
fi

# --- 4b) wings config: guarantee allowed_origins (panel console websocket) ---
if [ -f "$WINGS_CFG" ]; then
  if ! sudo grep -q "special-palm-tree-rrqg4vgj67cp6wp-8080.app.github.dev" "$WINGS_CFG" 2>/dev/null; then
    sudo cp "$WINGS_CFG" "$WINGS_CFG.bak"
    sudo python3 - "$WINGS_CFG" "https://special-palm-tree-rrqg4vgj67cp6wp-8080.app.github.dev" <<'PY2'
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
PY2
    sudo pkill -f "wings --config config.yml"
    sleep 3
    (cd "$STACK_DIR/wings" && sudo nohup ./wings --config config.yml >>/var/log/pterodactyl/wings.log 2>&1 &)
    sleep 8
  fi
fi

# --- 5) cloudflared wings tunnel + node fqdn sync (panel console websocket) ---
CF="$DIR/cloudflared"
if [ -x "$CF" ]; then
  if ! pgrep -f "cloudflared tunnel --url http://127.0.0.1:8081" >/dev/null 2>&1; then
    sudo nohup "$CF" tunnel --url http://127.0.0.1:8081 --no-autoupdate >"$DIR/wings-tunnel.log" 2>&1 &
    sleep 12
  fi
  HOST=$(sudo grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" "$DIR/wings-tunnel.log" 2>/dev/null | head -1)
  if [ -n "$HOST" ]; then
    echo "$HOST" > "$DIR/wings-hostname.txt"
    sudo docker exec ptero-database sh -c "mariadb -upterodactyl -pptero_test_password panel -e \"UPDATE nodes SET fqdn='$HOST', scheme='https', daemonListen=443, behind_proxy=1 WHERE id=1;\"" >/dev/null 2>&1 || true
    echo "wings tunnel: $HOST"
  fi
fi

# --- 5b) cloudflared PANEL tunnel (port 8080) + APP_URL sync (panel access) ---
if [ -x "$CF" ]; then
  if ! pgrep -f "cloudflared tunnel --url http://127.0.0.1:8080" >/dev/null 2>&1; then
    sudo nohup "$CF" tunnel --url http://127.0.0.1:8080 --no-autoupdate >"$DIR/panel-tunnel.log" 2>&1 &
    sleep 10
  fi
  PHOST=$(sudo grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" "$DIR/panel-tunnel.log" 2>/dev/null | head -1)
  if [ -z "$PHOST" ]; then
    PHOST=$(sudo grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" /tmp/panel-tunnel.log 2>/dev/null | head -1)
  fi
  if [ -n "$PHOST" ]; then
    PANEL_URL="https://$PHOST"
    echo "$PANEL_URL" > "$DIR/panel-address.txt"
    # sync panel APP_URL in docker-compose (recreate only when it changes)
    if sudo grep -q "APP_URL: " "$COMPOSE" 2>/dev/null && ! sudo grep -q "APP_URL: $PANEL_URL" "$COMPOSE"; then
      sudo sed -i "s|APP_URL: .*|APP_URL: $PANEL_URL|" "$COMPOSE"
      (cd "$STACK_DIR" && sudo docker compose up -d panel >/dev/null 2>&1)
      sleep 8
    fi
    # ensure wings allows the panel origin
    if ! sudo grep -q "$PHOST" "$WINGS_CFG" 2>/dev/null; then
      sudo python3 - "/home/codespace/pterodactyl-lab/wings/config.yml" "$PHOST" <<'PY2'
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
PY2
      sudo pkill -f "wings --config config.yml"
      sleep 3
      (cd "$STACK_DIR/wings" && sudo nohup ./wings --config config.yml >>/var/log/pterodactyl/wings.log 2>&1 &)
      sleep 8
    fi
    echo "panel tunnel: $PANEL_URL"
  fi
fi

# --- 6) local watchdog ---
if ! pgrep -f "keep_server_alive.sh" >/dev/null 2>&1; then
  sudo setsid bash -c 'exec /workspaces/tests/.keepalive/keep_server_alive.sh >>/tmp/keepalive.log 2>&1' </dev/null >/dev/null 2>&1 &
fi

# --- 7) publish tunnel addresses to the repo (cs2 reads these to reach the panel) ---
if git -C /workspaces/tests rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git -C /workspaces/tests diff --quiet -- .keepalive/panel-address.txt .keepalive/wings-hostname.txt 2>/dev/null; then
    git -C /workspaces/tests add .keepalive/panel-address.txt .keepalive/wings-hostname.txt 2>/dev/null
    git -C /workspaces/tests commit -m "sync tunnel addresses" -q 2>/dev/null
    git -C /workspaces/tests push -q 2>/dev/null || true
  fi
fi

echo "stack ok"

