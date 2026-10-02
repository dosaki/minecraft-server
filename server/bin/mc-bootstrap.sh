#!/bin/bash
# Every boot: install packages, render config, fetch jars, update DNS, start Paper + timers.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
OPT=/opt/minecraft
MC_HOME=/srv/minecraft
export AWS_REGION="$MC_REGION"

# Start idle timer first (it will power off if any later step fails); other failures leave the instance safe from billing.
cp "$OPT"/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl start mc-idle-check.timer

param() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text; }

rpm -q java-25-amazon-corretto-headless zstd python3 >/dev/null 2>&1 \
  || dnf install -y java-25-amazon-corretto-headless zstd python3

id minecraft >/dev/null 2>&1 || useradd --system --home-dir "$MC_HOME" --shell /sbin/nologin minecraft
install -d -o minecraft -g minecraft "$MC_HOME" "$MC_HOME/plugins" "$MC_HOME/plugins/squaremap"
install -d -m 750 -o root -g minecraft /etc/minecraft

rcon_password=$(param "$MC_RCON_PARAM")
install -m 640 -o root -g minecraft /dev/null /etc/minecraft/rcon.pass
printf '%s' "$rcon_password" > /etc/minecraft/rcon.pass

"$OPT/bin/mc-fetch-jars" "$OPT/config/versions.json" "$MC_HOME"
sed "s|@RCON_PASSWORD@|${rcon_password}|" "$OPT/config/server.properties.tmpl" > "$MC_HOME/server.properties"
chmod 640 "$MC_HOME/server.properties"
cp "$OPT/config/squaremap.yml" "$MC_HOME/plugins/squaremap/config.yml"
echo "eula=true" > "$MC_HOME/eula.txt"
# SSM /minecraft/players is the source of truth: start empty, then add via RCON (resolves UUIDs).
echo '[]' > "$MC_HOME/whitelist.json"
echo '[]' > "$MC_HOME/ops.json"
chown -R minecraft:minecraft "$MC_HOME"

"$OPT/bin/mc-update-dns.sh"
systemctl start minecraft.service mc-backup.timer mc-map-sync.timer

players_error=$({ param "$MC_PLAYERS_PARAM"; } 2>&1) || players_error=$?
if [[ "$players_error" == *"ParameterNotFound"* ]]; then
  echo "no players parameter yet"
  players='{}'
elif [[ -n "$players_error" && "$players_error" != "0" ]]; then
  echo "$players_error" >&2
  exit 1
else
  players="$players_error"
fi
printf '%s' "$players" | "$OPT/bin/mc-apply-players"
