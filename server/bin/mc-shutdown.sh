#!/bin/bash
# Back up, sync the map, then power off (instance stops). Used by idle check and deploys.
set -uo pipefail
BIN=${MC_BIN:-/opt/minecraft/bin}

"$BIN/mc-backup.sh" || echo "WARN: backup failed; powering off anyway" >&2
"$BIN/mc-map-sync.sh" || echo "WARN: map sync failed; powering off anyway" >&2
eval "${MC_POWEROFF:-systemctl poweroff}"
