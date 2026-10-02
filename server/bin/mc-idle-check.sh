#!/bin/bash
# Shut the instance down when nobody is online (run every 30 min by mc-idle-check.timer).
set -uo pipefail
BIN=${MC_BIN:-/opt/minecraft/bin}
RETRY_DELAY=${MC_RCON_RETRY_DELAY:-10}

if ! systemctl is-active --quiet minecraft.service; then
  echo "minecraft.service is not active; shutting down"
  exec "$BIN/mc-shutdown.sh"
fi

count=""
for attempt in 1 2 3; do
  if count=$("$BIN/mc-rcon" --player-count) && [[ $count =~ ^[0-9]+$ ]]; then
    break
  fi
  count=""
  echo "RCON attempt $attempt failed"
  [[ $attempt -lt 3 ]] && sleep "$RETRY_DELAY"
done

if [[ -z $count ]]; then
  echo "RCON unreachable after 3 attempts; shutting down"
  exec "$BIN/mc-shutdown.sh"
fi

if (( count > 0 )); then
  echo "$count player(s) online; staying up"
  exit 0
fi

echo "no players online; shutting down"
exec "$BIN/mc-shutdown.sh"
