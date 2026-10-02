#!/bin/bash
# Back up, sync the map, then power off (instance stops). Used by idle check and deploys.
set -uo pipefail
BIN=${MC_BIN:-/opt/minecraft/bin}

TIMEOUT=${MC_TIMEOUT_CMD:-timeout}

$TIMEOUT 45m "$BIN/mc-backup.sh" || echo "WARN: backup failed; powering off anyway" >&2
$TIMEOUT 20m "$BIN/mc-map-sync.sh" || echo "WARN: map sync failed; powering off anyway" >&2
eval "${MC_POWEROFF:-systemctl poweroff}"
