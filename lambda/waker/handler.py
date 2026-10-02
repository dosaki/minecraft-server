"""Start the Minecraft instance when its DNS name is queried (Route 53 query logs)."""
import base64
import gzip
import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

log = logging.getLogger()
log.setLevel(logging.INFO)


def wake_names() -> frozenset:
    raw = os.environ.get("WAKE_NAMES", "")
    return frozenset(n.strip().lower().rstrip(".") for n in raw.split(",") if n.strip())


def query_name(message: str):
    # version timestamp zone_id query_name query_type rcode protocol edge resolver_ip edns
    parts = message.split()
    if len(parts) < 5:
        return None
    return parts[3].lower().rstrip(".")


def decode_messages(event) -> list:
    payload = json.loads(gzip.decompress(base64.b64decode(event["awslogs"]["data"])))
    return [e["message"] for e in payload.get("logEvents", [])]


def should_wake(messages, names) -> bool:
    return any(query_name(m) in names for m in messages)


def _in_maintenance(ssm, param: str) -> bool:
    try:
        value = ssm.get_parameter(Name=param)["Parameter"]["Value"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "ParameterNotFound":
            return False
        raise
    return value.strip().lower() == "true"


def wake(ec2, ssm, instance_id: str, maintenance_param: str) -> str:
    if _in_maintenance(ssm, maintenance_param):
        return "maintenance"
    reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    state = reservations[0]["Instances"][0]["State"]["Name"]
    if state != "stopped":
        return f"already-{state}"
    try:
        ec2.start_instances(InstanceIds=[instance_id])
    except ClientError as e:
        if e.response["Error"]["Code"] == "IncorrectInstanceState":
            return "race"
        raise
    return "started"


def handler(event, context):
    if not should_wake(decode_messages(event), wake_names()):
        return {"result": "ignored"}
    region = os.environ["INSTANCE_REGION"]
    result = wake(
        boto3.client("ec2", region_name=region),
        boto3.client("ssm", region_name=region),
        os.environ["INSTANCE_ID"],
        os.environ["MAINTENANCE_PARAM"],
    )
    log.info("wake result: %s", result)
    return {"result": result}
