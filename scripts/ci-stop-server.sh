#!/bin/bash
# Deploy helper: warn players, then cleanly stop the instance. Usage: ci-stop-server.sh [INSTANCE_ID]
set -euo pipefail
id=${1:-}
if [[ -z $id ]]; then
  echo "no instance exists yet; nothing to stop"
  exit 0
fi

state() {
  aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

run_on_instance() {
  local params
  params=$(printf '{"commands":["%s"]}' "$1")
  for attempt in 1 2 3 4 5 6; do
    if aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters "$params" --query Command.CommandId --output text; then
      return 0
    fi
    echo "send-command attempt $attempt failed (SSM agent not ready?); retrying"
    sleep 10
  done
  return 1
}

s=$(state)
echo "instance $id is $s"
case $s in
  stopped|terminated)
    exit 0 ;;
  stopping)
    aws ec2 wait instance-stopped --instance-ids "$id"
    exit 0 ;;
  pending)
    aws ec2 wait instance-running --instance-ids "$id" ;;
esac

run_on_instance "/opt/minecraft/bin/mc-rcon say Shutdown for updates in 5 minutes" || true
sleep "${WARN_FIRST_SECONDS:-240}"
run_on_instance "/opt/minecraft/bin/mc-rcon say Shutdown for updates in 1 minute" || true
sleep "${WARN_SECOND_SECONDS:-60}"
# poweroff kills this command mid-flight; success is judged by the waiter below.
run_on_instance "/opt/minecraft/bin/mc-shutdown.sh" || true
aws ec2 wait instance-stopped --instance-ids "$id"
echo "instance $id stopped"
