import os
import stat
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/ci-stop-server.sh"


def run(tmp_path, state, instance_id="i-abc"):
    fake = tmp_path / "aws"
    log = tmp_path / "calls"
    fake.write_text(f"""#!/bin/bash
echo "$*" >> "{log}"
case "$1 $2" in
  "ec2 describe-instances") echo "{state}" ;;
  "ssm send-command") echo "cmd-1" ;;
esac
exit 0
""")
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}",
           "WARN_FIRST_SECONDS": "0", "WARN_SECOND_SECONDS": "0"}
    args = ["bash", str(SCRIPT)] + ([instance_id] if instance_id else [])
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls


def test_no_instance_yet_is_noop(tmp_path):
    result, calls = run(tmp_path, "stopped", instance_id="")
    assert result.returncode == 0 and calls == []


def test_stopped_instance_sends_nothing(tmp_path):
    result, calls = run(tmp_path, "stopped")
    assert result.returncode == 0
    assert not any(c.startswith("ssm send-command") for c in calls)


def test_running_instance_warns_then_shuts_down(tmp_path):
    result, calls = run(tmp_path, "running")
    assert result.returncode == 0, result.stderr
    sends = [c for c in calls if c.startswith("ssm send-command")]
    assert "Shutdown for updates in 5 minutes" in sends[0]
    assert "Shutdown for updates in 1 minute" in sends[1]
    assert "mc-shutdown.sh" in sends[2]
    assert any(c.startswith("ec2 wait instance-stopped") for c in calls)


def test_stopping_instance_just_waits(tmp_path):
    result, calls = run(tmp_path, "stopping")
    assert result.returncode == 0
    assert any(c.startswith("ec2 wait instance-stopped") for c in calls)
    assert not any(c.startswith("ssm send-command") for c in calls)
