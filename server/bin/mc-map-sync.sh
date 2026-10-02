#!/bin/bash
# Publish squaremap's static web output to the map bucket.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
MC_HOME=${MC_HOME:-/srv/minecraft}
web="$MC_HOME/plugins/squaremap/web"

if [[ ! -d $web ]]; then
  echo "no squaremap output yet; nothing to sync"
  exit 0
fi
aws s3 sync "$web" "s3://$MC_MAP_BUCKET/" --delete --only-show-errors --region "$MC_REGION"
