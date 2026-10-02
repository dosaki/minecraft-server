import base64
import gzip
import json

import boto3
import pytest
from botocore.stub import Stubber

import handler

LOG = "1.0 2026-10-02T21:14:00Z Z0123 {name} {qtype} NOERROR UDP DUB56-P1 8.8.8.8 -"


def event_for(*messages):
    payload = {"logEvents": [{"id": str(i), "timestamp": 0, "message": m} for i, m in enumerate(messages)]}
    data = base64.b64encode(gzip.compress(json.dumps(payload).encode())).decode()
    return {"awslogs": {"data": data}}


@pytest.fixture(autouse=True)
def env(monkeypatch):
    monkeypatch.setenv("INSTANCE_ID", "i-abc")
    monkeypatch.setenv("INSTANCE_REGION", "eu-west-1")
    monkeypatch.setenv("MAINTENANCE_PARAM", "/minecraft/maintenance")
    monkeypatch.setenv("WAKE_NAMES", "minecraft.dosaki.net,_minecraft._tcp.minecraft.dosaki.net")


@pytest.mark.parametrize("name", [
    "minecraft.dosaki.net", "MiNeCrAfT.dosaki.NET", "minecraft.dosaki.net.",
    "_minecraft._tcp.minecraft.dosaki.net",
])
def test_wake_names_match(name):
    assert handler.should_wake([LOG.format(name=name, qtype="A")], handler.wake_names())


@pytest.mark.parametrize("name", ["map.minecraft.dosaki.net", "dosaki.net", "xminecraft.dosaki.net"])
def test_other_names_ignored(name):
    assert not handler.should_wake([LOG.format(name=name, qtype="A")], handler.wake_names())


def test_short_line_ignored():
    assert handler.query_name("garbage") is None


def clients():
    ec2 = boto3.client("ec2", region_name="eu-west-1")
    ssm = boto3.client("ssm", region_name="eu-west-1")
    return ec2, ssm, Stubber(ec2), Stubber(ssm)


def stub_maintenance(stub, value):
    stub.add_response("get_parameter", {"Parameter": {"Name": "/minecraft/maintenance", "Value": value}},
                      {"Name": "/minecraft/maintenance"})


def stub_state(stub, state):
    stub.add_response("describe_instances",
                      {"Reservations": [{"Instances": [{"InstanceId": "i-abc", "State": {"Name": state}}]}]},
                      {"InstanceIds": ["i-abc"]})


def test_maintenance_blocks_start():
    ec2, ssm, e, s = clients()
    stub_maintenance(s, "true")
    with e, s:
        assert handler.wake(ec2, ssm, "i-abc", "/minecraft/maintenance") == "maintenance"


def test_missing_maintenance_param_is_not_maintenance():
    ec2, ssm, e, s = clients()
    s.add_client_error("get_parameter", service_error_code="ParameterNotFound")
    stub_state(e, "running")
    with e, s:
        assert handler.wake(ec2, ssm, "i-abc", "/minecraft/maintenance") == "already-running"


def test_stopped_instance_is_started():
    ec2, ssm, e, s = clients()
    stub_maintenance(s, "false")
    stub_state(e, "stopped")
    e.add_response("start_instances", {"StartingInstances": []}, {"InstanceIds": ["i-abc"]})
    with e, s:
        assert handler.wake(ec2, ssm, "i-abc", "/minecraft/maintenance") == "started"


@pytest.mark.parametrize("state", ["pending", "running", "stopping", "shutting-down"])
def test_non_stopped_states_are_noop(state):
    ec2, ssm, e, s = clients()
    stub_maintenance(s, "false")
    stub_state(e, state)
    with e, s:
        assert handler.wake(ec2, ssm, "i-abc", "/minecraft/maintenance") == f"already-{state}"


def test_start_race_is_swallowed():
    ec2, ssm, e, s = clients()
    stub_maintenance(s, "false")
    stub_state(e, "stopped")
    e.add_client_error("start_instances", service_error_code="IncorrectInstanceState")
    with e, s:
        assert handler.wake(ec2, ssm, "i-abc", "/minecraft/maintenance") == "race"


def test_handler_ignores_irrelevant_batch_without_aws_calls(monkeypatch):
    monkeypatch.setattr(handler.boto3, "client", lambda *a, **k: pytest.fail("no AWS call expected"))
    ev = event_for(LOG.format(name="map.minecraft.dosaki.net", qtype="A"))
    assert handler.handler(ev, None) == {"result": "ignored"}
