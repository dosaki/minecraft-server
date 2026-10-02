#!/bin/bash
# Point the server's A record at this instance's current public IPv4.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env

token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
ip=$(curl -sf -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/public-ipv4)
if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "no public IPv4 found (got '$ip')" >&2
  exit 1
fi

change=$(printf '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","TTL":30,"ResourceRecords":[{"Value":"%s"}]}}]}' "$MC_RECORD_NAME" "$ip")
aws route53 change-resource-record-sets --hosted-zone-id "$MC_ZONE_ID" --change-batch "$change" >/dev/null
echo "$MC_RECORD_NAME -> $ip"
