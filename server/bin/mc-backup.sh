#!/bin/bash
# Archive the server directory and upload it to S3 using GFS keys.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
BIN=${MC_BIN:-/opt/minecraft/bin}
MC_HOME=${MC_HOME:-/srv/minecraft}
export AWS_REGION="$MC_REGION"

exec 9>/run/mc-backup.lock
if ! flock -w 1800 9; then
  echo "could not get backup lock within 30 minutes (another backup or restore is running)" >&2
  exit 1
fi

archive=$(mktemp /var/tmp/mc-backup.XXXXXX.tar.zst)
saving_paused=0
cleanup() {
  if (( saving_paused )); then "$BIN/mc-rcon" save-on >/dev/null 2>&1 || true; fi
  rm -f "$archive"
}
trap cleanup EXIT

if "$BIN/mc-rcon" save-off >/dev/null 2>&1; then
  saving_paused=1
  "$BIN/mc-rcon" --timeout 120 save-all flush >/dev/null
else
  echo "RCON unavailable; archiving files as they are"
fi

set +e
tar -C "$MC_HOME" \
  --exclude=./logs --exclude=./cache --exclude=./libraries --exclude=./versions \
  --exclude=./paper.jar --exclude='./plugins/*.jar' --exclude=./plugins/.paper-remapped \
  --exclude=./plugins/squaremap/web \
  --exclude=./plugins/CraftEngine/libs --exclude=./plugins/CraftEngine/generated --exclude='./restore-backup-*' \
  -cf - . | zstd -q -T0 -10 -f -o "$archive"
rc=("${PIPESTATUS[@]}")
set -e
if (( rc[0] > 1 || rc[1] != 0 )); then echo "archive failed: tar=${rc[0]} zstd=${rc[1]}" >&2; exit 1; fi

if (( saving_paused )); then
  "$BIN/mc-rcon" save-on >/dev/null || echo "WARN: save-on failed" >&2
  saving_paused=0
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
output_father=$(aws s3api list-objects-v2 --bucket "$MC_BACKUP_BUCKET" --prefix "father/" \
  --query 'Contents[].Key' --output text)
output_grandfather=$(aws s3api list-objects-v2 --bucket "$MC_BACKUP_BUCKET" --prefix "grandfather/" \
  --query 'Contents[].Key' --output text)
existing=$(printf '%s\n' "$output_father" "$output_grandfather" | tr '\t' '\n' | grep -v '^None$' || true)
mapfile -t keys < <(printf '%s\n' "$existing" | "$BIN/mc-gfs-keys" --now "$now")

if (( ${#keys[@]} == 0 )); then echo "no backup keys generated" >&2; exit 1; fi

aws s3 cp --only-show-errors "$archive" "s3://$MC_BACKUP_BUCKET/${keys[0]}"
for key in "${keys[@]:1}"; do
  aws s3 cp --only-show-errors --copy-props none "s3://$MC_BACKUP_BUCKET/${keys[0]}" "s3://$MC_BACKUP_BUCKET/$key"
done
echo "backup written: ${keys[*]}"
