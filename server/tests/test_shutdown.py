import os
import stat
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "server/bin/mc-shutdown.sh"


def make_exe(path: Path, body: str):
    path.write_text("#!/bin/bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def run(tmp_path, backup_exit):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "log"
    make_exe(bin_dir / "mc-backup.sh", f'echo backup >> "{log}"; exit {backup_exit}\n')
    make_exe(bin_dir / "mc-map-sync.sh", f'echo map >> "{log}"\n')
    env = {**os.environ, "MC_BIN": str(bin_dir), "MC_POWEROFF": f'echo poweroff >> "{log}"'}
    subprocess.run(["bash", str(SCRIPT)], env=env, check=True)
    return log.read_text().split()


def test_order_is_backup_map_poweroff(tmp_path):
    assert run(tmp_path, 0) == ["backup", "map", "poweroff"]


def test_backup_failure_still_powers_off(tmp_path):
    assert run(tmp_path, 1) == ["backup", "map", "poweroff"]
