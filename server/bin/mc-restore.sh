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
trap 'rm -f "$archive"' EXIT

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
