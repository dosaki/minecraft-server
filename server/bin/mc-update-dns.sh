#!/bin/bash
# Point the server's A record at this instance's current public IPv4.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env

ip=""
for attempt in {1..10}; do
  token=$(curl -sf --max-time 5 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60") || token=""
  if [[ -z "$token" ]]; then
    if [[ $attempt -lt 10 ]]; then
      sleep 3
      continue
    else
      echo "failed to get EC2 metadata token" >&2
      exit 1
    fi
  fi
  ip=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/public-ipv4) || ip=""
  if [[ -z "$ip" ]]; then
    if [[ $attempt -lt 10 ]]; then
      sleep 3
      continue
    else
      echo "failed to get public IPv4 from EC2 metadata" >&2
      exit 1
    fi
  fi
  break
done

if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "no public IPv4 found (got '$ip')" >&2
  exit 1
fi

change=$(printf '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","TTL":30,"ResourceRecords":[{"Value":"%s"}]}}]}' "$MC_RECORD_NAME" "$ip")
aws route53 change-resource-record-sets --hosted-zone-id "$MC_ZONE_ID" --change-batch "$change" >/dev/null
echo "$MC_RECORD_NAME -> $ip"
