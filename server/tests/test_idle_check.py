import os
import stat
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "server/bin/mc-idle-check.sh"


def make_exe(path: Path, body: str):
    path.write_text("#!/bin/bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def run(tmp_path, rcon_body, active=True):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_path = tmp_path / "path"
    fake_path.mkdir()
    make_exe(bin_dir / "mc-rcon", rcon_body)
    make_exe(bin_dir / "mc-shutdown.sh", f'touch "{tmp_path}/shutdown"\n')
    make_exe(fake_path / "systemctl", "exit 0\n" if active else "exit 3\n")
    env = {**os.environ, "MC_BIN": str(bin_dir), "MC_RCON_RETRY_DELAY": "0",
           "PATH": f"{fake_path}:{os.environ['PATH']}"}
    result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
    return result, (tmp_path / "shutdown").exists()


def test_players_online_stays_up(tmp_path):
    result, shut = run(tmp_path, "echo 2\n")
    assert result.returncode == 0 and not shut


def test_zero_players_shuts_down(tmp_path):
    _, shut = run(tmp_path, "echo 0\n")
    assert shut


def test_service_inactive_shuts_down(tmp_path):
    _, shut = run(tmp_path, "echo 5\n", active=False)
    assert shut


def test_rcon_dead_shuts_down(tmp_path):
    _, shut = run(tmp_path, "exit 1\n")
    assert shut


def test_transient_rcon_failure_does_not_shut_down(tmp_path):
    counter = tmp_path / "count"
    body = f'n=$(cat "{counter}" 2>/dev/null || echo 0); echo $((n+1)) > "{counter}"\n' \
           f'[ "$n" -lt 2 ] && exit 1\necho 3\n'
    _, shut = run(tmp_path, body)
    assert not shut
