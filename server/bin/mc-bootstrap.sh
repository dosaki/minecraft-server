#!/bin/bash
# Every boot: install packages, render config, fetch jars, update DNS, start Paper + timers.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
OPT=/opt/minecraft
MC_HOME=/srv/minecraft
export AWS_REGION="$MC_REGION"

# Start idle timer first (it will power off if any later step fails); other failures leave the instance safe from billing.
# "enable" makes later boots start it from systemd even if the S3 config fetch fails.
cp "$OPT"/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mc-idle-check.timer

param() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text; }

rpm -q java-25-amazon-corretto-headless zstd python3 >/dev/null 2>&1 \
  || dnf install -y java-25-amazon-corretto-headless zstd python3

id minecraft >/dev/null 2>&1 || useradd --system --home-dir "$MC_HOME" --shell /sbin/nologin minecraft
install -d -o minecraft -g minecraft "$MC_HOME" "$MC_HOME/plugins" "$MC_HOME/plugins/squaremap" "$MC_HOME/plugins/CraftEngine"
install -d -m 750 -o root -g minecraft /etc/minecraft

rcon_password=$(param "$MC_RCON_PARAM")
install -m 640 -o root -g minecraft /dev/null /etc/minecraft/rcon.pass
printf '%s' "$rcon_password" > /etc/minecraft/rcon.pass

"$OPT/bin/mc-fetch-jars" "$OPT/config/versions.json" "$MC_HOME"
sed "s|@RCON_PASSWORD@|${rcon_password}|" "$OPT/config/server.properties.tmpl" > "$MC_HOME/server.properties"
chmod 640 "$MC_HOME/server.properties"
cp "$OPT/config/squaremap.yml" "$MC_HOME/plugins/squaremap/config.yml"
# Full default config plus our edits, replaced each boot; the pack URL is the DNS record on the game port.
sed "s|@RECORD_NAME@|${MC_RECORD_NAME}|g" "$OPT/config/craftengine.yml.tmpl" > "$MC_HOME/plugins/CraftEngine/config.yml"
# Our datapacks (gamerules etc.) are replaced wholesale each boot; the game enables new packs
# found in world/datapacks on load, including when it is generating a fresh world.
for pack in "$OPT"/datapacks/*/; do
  [[ -d $pack ]] || continue
  name=$(basename "$pack")
  rm -rf "$MC_HOME/world/datapacks/$name"
  install -d "$MC_HOME/world/datapacks"
  cp -r "$pack" "$MC_HOME/world/datapacks/$name"
done
echo "eula=true" > "$MC_HOME/eula.txt"
# SSM /minecraft/players is the source of truth: start empty, then add via RCON (resolves UUIDs).
echo '[]' > "$MC_HOME/whitelist.json"
echo '[]' > "$MC_HOME/ops.json"
chown -R minecraft:minecraft "$MC_HOME"

"$OPT/bin/mc-update-dns.sh"
systemctl start minecraft.service mc-backup.timer mc-map-sync.timer

err=$(mktemp)
if players=$(param "$MC_PLAYERS_PARAM" 2>"$err"); then
  :
elif grep -q ParameterNotFound "$err"; then
  echo "no players parameter yet; starting with an empty whitelist"
  players='{}'
else
  cat "$err" >&2
  rm -f "$err"
  exit 1
fi
rm -f "$err"
printf '%s' "$players" | "$OPT/bin/mc-apply-players"
