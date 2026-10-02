#!/bin/bash
# Upload the family player list to SSM. Usage: scripts/set-players.sh players.json
set -euo pipefail
file=${1:?usage: scripts/set-players.sh players.json (see scripts/players.example.json)}
here=$(cd "$(dirname "$0")" && pwd)
python3 "$here/../server/lib/players.py" --validate "$file"
aws ssm put-parameter --profile "${AWS_PROFILE_NAME:-dosaki}" --region eu-west-1 \
  --name /minecraft/players --type SecureString --overwrite --value "file://$file" >/dev/null
echo "Players updated. They apply the next time the server boots."
