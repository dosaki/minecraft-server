#!/bin/bash
# Restore a backup: mc-restore.sh <s3-key>, e.g. father/2026-W40.tar.zst
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
key=${1:?usage: mc-restore.sh S3_KEY}
MC_HOME=/srv/minecraft
stamp=$(date -u +%Y%m%dT%H%M%SZ)
aside="$MC_HOME/restore-backup-$stamp"
archive=$(mktemp /var/tmp/mc-restore.XXXXXX.tar.zst)
# Re-arm the idle timer 30 min after exit: starting it directly would fire it at once
# (OnBootSec has passed) and shut down while Paper is still starting.
trap 'rm -f "$archive"; systemd-run --on-active=30min --unit="mc-idle-rearm-$stamp" systemctl start mc-idle-check.timer' EXIT

# Hold the backup lock for the whole restore so the hourly backup cannot upload a world-less archive.
exec 9>/run/mc-backup.lock
if ! flock -w 1800 9; then echo "could not get backup lock within 30 minutes" >&2; exit 1; fi

systemctl stop mc-idle-check.timer
aws s3 cp --only-show-errors --region "$MC_REGION" "s3://$MC_BACKUP_BUCKET/$key" "$archive"
systemctl stop minecraft.service
mkdir -p "$aside"
for dir in world world_nether world_the_end; do
  if [[ -e $MC_HOME/$dir ]]; then mv "$MC_HOME/$dir" "$aside/"; fi
done
zstd -dc "$archive" | tar -C "$MC_HOME" -xf -
chown -R minecraft:minecraft "$MC_HOME"
systemctl start minecraft.service
echo "restored $key; previous world kept in $aside"
