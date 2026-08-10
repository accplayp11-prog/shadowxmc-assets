#!/bin/bash
LOG=/tmp/keepalive2.log
LOCK=/tmp/keepalive2.lock
exec 9>"$LOCK"
flock -n 9 || exit 0
while true; do
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  OUT=$(bash /workspaces/tests/.keepalive/ensure_stack2.sh 2>&1 | tail -2)
  echo "[$TS] $(echo "$OUT" | tr '\n' ' ')" >> "$LOG"
  tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  sleep 60
done
