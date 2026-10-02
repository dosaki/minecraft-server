#!/bin/bash
# Archive the server directory and upload it to S3 using GFS keys.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
BIN=${MC_BIN:-/opt/minecraft/bin}
MC_HOME=${MC_HOME:-/srv/minecraft}
export AWS_REGION="$MC_REGION"

exec 9>/run/mc-backup.lock
flock 9

archive=$(mktemp /var/tmp/mc-backup.XXXXXX.tar.zst)
saving_paused=0
cleanup() {
  if (( saving_paused )); then "$BIN/mc-rcon" save-on >/dev/null 2>&1 || true; fi
  rm -f "$archive"
}
trap cleanup EXIT

if "$BIN/mc-rcon" save-off >/dev/null 2>&1; then
  saving_paused=1
  "$BIN/mc-rcon" save-all flush >/dev/null
else
  echo "RCON unavailable; archiving files as they are"
fi

tar -C "$MC_HOME" \
  --exclude=./logs --exclude=./cache --exclude=./libraries --exclude=./versions \
  --exclude=./paper.jar --exclude='./plugins/*.jar' --exclude=./plugins/.paper-remapped \
  --exclude=./plugins/squaremap/web \
  -cf - . | zstd -q -T0 -10 -f -o "$archive"

if (( saving_paused )); then
  "$BIN/mc-rcon" save-on >/dev/null || true
  saving_paused=0
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
existing=$(
  for prefix in father/ grandfather/; do
    aws s3api list-objects-v2 --bucket "$MC_BACKUP_BUCKET" --prefix "$prefix" \
      --query 'Contents[].Key' --output text
  done | tr '\t' '\n' | grep -v '^None$' || true
)
mapfile -t keys < <(printf '%s\n' "$existing" | "$BIN/mc-gfs-keys" --now "$now")

aws s3 cp --only-show-errors "$archive" "s3://$MC_BACKUP_BUCKET/${keys[0]}"
for key in "${keys[@]:1}"; do
  aws s3 cp --only-show-errors "s3://$MC_BACKUP_BUCKET/${keys[0]}" "s3://$MC_BACKUP_BUCKET/$key"
done
echo "backup written: ${keys[*]}"
