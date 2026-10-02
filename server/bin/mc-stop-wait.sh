#!/bin/bash
# ExecStop for minecraft.service: ask Paper to stop, then wait for the JVM to exit.
# (systemd SIGTERMs remaining processes as soon as ExecStop returns, so we must wait here.)
set -uo pipefail
pid=${1:?usage: mc-stop-wait.sh PID}
/opt/minecraft/bin/mc-rcon stop || exit 0   # RCON down: let systemd's SIGTERM handle it
while kill -0 "$pid" 2>/dev/null; do
  sleep 1
done
