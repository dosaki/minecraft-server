# On-demand Family Minecraft Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Paper Minecraft server on AWS that starts when someone looks up `minecraft.dosaki.net`, stops itself when idle, keeps GFS backups in S3, publishes a squaremap web map, and redeploys from GitHub Actions on merge to `main`.

**Architecture:**
- Route 53 query logs for a child zone feed a us-east-1 Lambda, which starts a stopped EC2 instance in eu-west-1.
- On every boot the instance pulls its scripts and config from S3, updates its own DNS record and runs Paper.
- systemd timers handle idle shutdown (30 min), backups (60 min) and map sync (10 min).
- Terraform manages everything. GitHub Actions authenticates to AWS with OIDC.

**Tech Stack:**
- Terraform 1.13 with AWS provider ~> 6.0
- Python 3.13 (Lambda) and python3 on Amazon Linux 2023 (server helpers, standard library only)
- bash + systemd
- GitHub Actions, pytest, shellcheck

**Spec:** `docs/superpowers/specs/2026-10-02-minecraft-on-demand-design.md`

## Global Constraints

- AWS profile: `dosaki` for all local commands (`--profile dosaki`, `-backend-config="profile=dosaki"`). Never the default profile.
- Regions: server, backups, map and SSM in `eu-west-1`. Route 53 query log group, waker Lambda and ACM certificate for CloudFront in `us-east-1`.
- Names:
  - DNS: `minecraft.dosaki.net` (child zone), `map.minecraft.dosaki.net`.
  - Buckets: `dosaki-minecraft-backups`, `dosaki-minecraft-map`, `dosaki-minecraft-tfstate`.
- IAM:
  - Stack roles are named `minecraft-server-*`.
  - CI roles are `gha-minecraft-deploy` and `gha-minecraft-plan`. This is deliberately outside the `minecraft-server-*` pattern, so the deploy role cannot edit its own permissions.
- SSM parameters: `/minecraft/players` (SecureString, not managed by Terraform), `/minecraft/rcon-password` (SecureString), `/minecraft/maintenance` (String `true`/`false`).
- Instance: `m7g.xlarge`, Amazon Linux 2023 arm64, 30 GB gp3, `instance_initiated_shutdown_behavior = "stop"`, IMDSv2 required, no SSH, only `25565/tcp` inbound.
- Versions:
  - Paper 26.2 build 129: `paper-26.2-129.jar`, sha256 `b1d8f6bfa1b6101fa8e947b53041cb3bdf5540e7b83b6547ca19ba7edefeb083`. Needs Java ≥ 25, so use `java-25-amazon-corretto-headless`.
  - squaremap 1.3.15: `squaremap-paper-mc26.2-1.3.15.jar`, sha256 `68a4ecbcac39f83b9f974aab9d624a3a07001fae4982cc358ebfab73b49885af`.
- Java heap: `-Xms12G -Xmx12G`.
- Timers:
  - idle check: `OnBootSec=30min`, `OnUnitActiveSec=30min`
  - backup: 60 min
  - map sync: 10 min
- GFS keys (UTC): `son/YYYY-MM-DD.tar.zst` (overwritten, expires after 14 d), `father/YYYY-Www.tar.zst` (56 d), `grandfather/YYYY-MM.tar.zst` (365 d), `latest/world.tar.zst` (never expires).
- Deploy broadcast text, exact: `Shutdown for updates in 5 minutes`, then `Shutdown for updates in 1 minute` after 240 s, then shut down after another 60 s.
- Public repo: no usernames, emails, account IDs or credentials committed. `players.json` is gitignored.
- RCON: port 25575. Vanilla binds it to all interfaces; the security group never opens it, which meets the spec's "never exposed" requirement.

## Review Focus

1. **RCON hiccup while people are playing.** One slow or failed `list` during a lag spike must not shut the server down on players. The idle check retries 3 times, 10 s apart, before treating RCON as dead (Task 4 test `test_transient_rcon_failure_does_not_shut_down`).
2. **Malicious or typo'd player names in SSM.** A name like `bob; op mallory` must never reach RCON. Names must match `^[A-Za-z0-9_]{3,16}$`, otherwise the whole file is rejected (Task 2 test `test_rejects_injection_in_name`).
3. **ISO-week prefix collision.** `father/2026-W4…` must not count as week 40 already being backed up. Matching uses exact keys (Task 1 test `test_week_4_does_not_match_week_40`).
4. **Deploy hitting the instance in an odd state.** Before the first apply there is no instance; it may also be `pending` or `stopping`. The stop script must handle each case without hanging or failing the deploy (Task 6 tests in `server/tests/test_ci_stop_server.py`).
5. **Stale map from CDN caching.** After a play session, the map should show new terrain within minutes, not a day later. CloudFront default TTL is 300 s (Task 9, checked in the Task 12 smoke test).

---

## File Structure

```
.gitignore                         # + players.json, terraform/.build/
pyproject.toml                     # pytest config (testpaths, pythonpath)
Makefile                           # test / lint / fmt targets
lambda/waker/handler.py            # DNS-log → start instance
lambda/waker/tests/test_handler.py
server/lib/gfs.py                  # pure GFS key classification + CLI
server/lib/mcrcon.py               # RCON client + list-output parsing
server/lib/players.py              # validate players JSON → RCON commands
server/lib/jars.py                 # checksum-verified jar downloads
server/lib/tests/test_gfs.py
server/lib/tests/test_mcrcon.py
server/lib/tests/test_players.py
server/lib/tests/test_jars.py
server/bin/mc-rcon                 # CLI around mcrcon (python)
server/bin/mc-gfs-keys             # CLI around gfs (python)
server/bin/mc-apply-players        # CLI around players (python)
server/bin/mc-fetch-jars           # CLI around jars (python)
server/bin/mc-bootstrap.sh         # every-boot setup
server/bin/mc-update-dns.sh
server/bin/mc-idle-check.sh
server/bin/mc-shutdown.sh
server/bin/mc-stop-wait.sh         # ExecStop helper: rcon stop + wait for PID
server/bin/mc-backup.sh
server/bin/mc-map-sync.sh
server/bin/mc-restore.sh
server/systemd/minecraft.service
server/systemd/mc-idle-check.{service,timer}
server/systemd/mc-backup.{service,timer}
server/systemd/mc-map-sync.{service,timer}
server/config/server.properties.tmpl
server/config/squaremap.yml
server/config/versions.json
server/tests/test_idle_check.py    # bash script tested with fake binaries
server/tests/test_shutdown.py
server/tests/test_ci_stop_server.py
scripts/set-players.sh
scripts/ci-stop-server.sh
scripts/players.example.json
bootstrap/main.tf                  # state bucket, OIDC, CI roles
terraform/{providers,backend,variables,locals,outputs}.tf
terraform/dns.tf  terraform/waker.tf  terraform/server.tf
terraform/backups.tf  terraform/config_upload.tf  terraform/map.tf  terraform/budget.tf
terraform/templates/user_data.sh.tftpl
.github/workflows/ci.yml  .github/workflows/deploy.yml
README.md
```

Work on branch `feat/initial-implementation`. Merging it to `main` triggers the first deploy (Task 11).

---

### Task 1: Project tooling + GFS key classification

**Files:**
- Create: `pyproject.toml`, `Makefile`, `server/lib/gfs.py`, `server/lib/tests/test_gfs.py`, `server/bin/mc-gfs-keys`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `gfs.keys_for_backup(now: datetime, existing: Iterable[str]) -> list[str]`. The first element is always the son key (the upload target); the rest are server-side copy targets, ending with `latest/world.tar.zst`.
- Produces: CLI `mc-gfs-keys --now 2026-10-02T21:14:00Z`. Reads existing keys (one per line) from stdin and prints the keys to write, one per line.

- [ ] **Step 1: Create the branch and tooling**

```bash
cd /Users/tiagocorreia/pdev/minecraft && git checkout -b feat/initial-implementation
```

`pyproject.toml`:
```toml
[tool.pytest.ini_options]
testpaths = ["lambda/waker/tests", "server/lib/tests", "server/tests"]
pythonpath = ["lambda/waker", "server/lib"]
```

`Makefile`:
```make
.PHONY: test lint fmt
test:
	python3 -m pytest -q
lint:
	shellcheck server/bin/*.sh scripts/*.sh
	terraform fmt -check -recursive
fmt:
	terraform fmt -recursive
```

Append to `.gitignore`:
```
players.json
terraform/.build/
.terraform.lock.hcl.bak
```

- [ ] **Step 2: Write the failing tests** — `server/lib/tests/test_gfs.py`

```python
from datetime import datetime, timezone

import pytest

from gfs import keys_for_backup


def utc(*args):
    return datetime(*args, tzinfo=timezone.utc)


def test_first_backup_ever_writes_all_tiers():
    assert keys_for_backup(utc(2026, 10, 2, 21, 14), []) == [
        "son/2026-10-02.tar.zst",
        "father/2026-W40.tar.zst",
        "grandfather/2026-10.tar.zst",
        "latest/world.tar.zst",
    ]


def test_same_week_and_month_only_son_and_latest():
    existing = ["father/2026-W40.tar.zst", "grandfather/2026-10.tar.zst", "son/2026-10-02.tar.zst"]
    assert keys_for_backup(utc(2026, 10, 2, 23, 0), existing) == [
        "son/2026-10-02.tar.zst",
        "latest/world.tar.zst",
    ]


def test_new_iso_week_adds_father():
    existing = ["father/2026-W40.tar.zst", "grandfather/2026-10.tar.zst"]
    # 2026-10-05 is Monday of ISO week 41
    assert keys_for_backup(utc(2026, 10, 5, 18, 0), existing) == [
        "son/2026-10-05.tar.zst",
        "father/2026-W41.tar.zst",
        "latest/world.tar.zst",
    ]


def test_new_month_adds_grandfather():
    existing = ["father/2026-W44.tar.zst", "grandfather/2026-10.tar.zst"]
    # 2026-11-01 is a Sunday, still ISO week 44
    assert keys_for_backup(utc(2026, 11, 1, 10, 0), existing) == [
        "son/2026-11-01.tar.zst",
        "grandfather/2026-11.tar.zst",
        "latest/world.tar.zst",
    ]


def test_year_boundary_uses_iso_week_year():
    # 2027-01-01 is a Friday in ISO week 2026-W53
    existing = ["father/2026-W53.tar.zst", "grandfather/2026-12.tar.zst"]
    assert keys_for_backup(utc(2027, 1, 1, 12, 0), existing) == [
        "son/2027-01-01.tar.zst",
        "grandfather/2027-01.tar.zst",
        "latest/world.tar.zst",
    ]


def test_week_4_does_not_match_week_40():
    existing = ["father/2026-W4.tar.zst", "father/2026-W04.tar.zst"]
    assert "father/2026-W40.tar.zst" in keys_for_backup(utc(2026, 10, 2), existing)


def test_rejects_naive_datetime():
    with pytest.raises(ValueError):
        keys_for_backup(datetime(2026, 10, 2), [])


def test_converts_non_utc_to_utc():
    from datetime import timedelta
    # 00:30 on Oct 3 at +02:00 is 22:30 UTC on Oct 2
    tz = timezone(timedelta(hours=2))
    assert keys_for_backup(datetime(2026, 10, 3, 0, 30, tzinfo=tz), [])[0] == "son/2026-10-02.tar.zst"
```

- [ ] **Step 3: Run to verify failure**

Run: `python3 -m pytest server/lib/tests/test_gfs.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'gfs'`

- [ ] **Step 4: Implement** — `server/lib/gfs.py`

```python
"""Grandfather/father/son backup key classification (pure, UTC)."""
from datetime import datetime, timezone
from typing import Iterable

LATEST_KEY = "latest/world.tar.zst"


def keys_for_backup(now: datetime, existing: Iterable[str]) -> list[str]:
    """Return S3 keys to write for a backup taken at `now`.

    The first key is the son (upload target); the rest are server-side copies.
    """
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    now = now.astimezone(timezone.utc)
    existing = set(existing)
    iso_year, iso_week, _ = now.isocalendar()

    son = f"son/{now:%Y-%m-%d}.tar.zst"
    father = f"father/{iso_year}-W{iso_week:02d}.tar.zst"
    grandfather = f"grandfather/{now:%Y-%m}.tar.zst"

    keys = [son]
    if father not in existing:
        keys.append(father)
    if grandfather not in existing:
        keys.append(grandfather)
    keys.append(LATEST_KEY)
    return keys
```

`server/bin/mc-gfs-keys`:
```python
#!/usr/bin/env python3
"""Print GFS keys for a backup. Existing keys are read from stdin, one per line."""
import argparse
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))
from gfs import keys_for_backup  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--now", required=True, help="ISO-8601 UTC timestamp, e.g. 2026-10-02T21:14:00Z")
    args = parser.parse_args()
    now = datetime.fromisoformat(args.now.replace("Z", "+00:00"))
    existing = [line.strip() for line in sys.stdin if line.strip()]
    print("\n".join(keys_for_backup(now, existing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run tests and the CLI**

Run: `python3 -m pytest server/lib/tests/test_gfs.py -q && chmod +x server/bin/mc-gfs-keys && printf 'father/2026-W40.tar.zst\n' | server/bin/mc-gfs-keys --now 2026-10-02T21:14:00Z`
Expected: `8 passed`, then the CLI prints `son/2026-10-02.tar.zst`, `grandfather/2026-10.tar.zst`, `latest/world.tar.zst`.

- [ ] **Step 6: Commit**

```bash
git add pyproject.toml Makefile .gitignore server/lib/gfs.py server/lib/tests/test_gfs.py server/bin/mc-gfs-keys
git commit -m "feat: GFS backup key classification"
```

---

### Task 2: RCON client, player list handling, jar fetcher

**Files:**
- Create: `server/lib/mcrcon.py`, `server/lib/players.py`, `server/lib/jars.py`
- Create: `server/lib/tests/test_mcrcon.py`, `server/lib/tests/test_players.py`, `server/lib/tests/test_jars.py`
- Create: `server/bin/mc-rcon`, `server/bin/mc-apply-players`, `server/bin/mc-fetch-jars`
- Create: `server/config/versions.json`, `scripts/players.example.json`

**Interfaces:**
- Produces:
  - `mcrcon.Rcon(host, port, password, timeout=10)` (context manager) with `.command(cmd: str) -> str`
  - `mcrcon.RconError`
  - `mcrcon.player_count(list_output: str) -> int`
- Produces:
  - `players.parse_players(text: str) -> dict` returning `{"ops": [...], "whitelist": [...]}`; ops are always also whitelisted.
  - `players.commands_for(players: dict) -> list[str]`
  - `players.PlayersError`
- Produces:
  - `jars.ensure_file(url, sha256, dest, opener=urllib.request.urlopen) -> bool` (True if it downloaded)
  - `jars.sync_jars(manifest: dict, mc_home: str, opener=...) -> None`
- Produces CLIs:
  - `mc-rcon [--player-count] [cmd ...]`: password from `/etc/minecraft/rcon.pass`; exits 1 on failure.
  - `mc-apply-players`: reads JSON on stdin, waits up to 300 s for RCON.
  - `mc-fetch-jars <versions.json> <mc_home>`
  - `players.py --validate FILE`

- [ ] **Step 1: Write failing tests** — `server/lib/tests/test_mcrcon.py`

```python
import socket
import struct
import threading

import pytest

from mcrcon import Rcon, RconError, player_count


def _packet(req_id, kind, body):
    data = struct.pack("<ii", req_id, kind) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(data)) + data


def _read_packet(conn):
    length = struct.unpack("<i", conn.recv(4))[0]
    data = b""
    while len(data) < length:
        data += conn.recv(length - len(data))
    req_id, kind = struct.unpack("<ii", data[:8])
    return req_id, kind, data[8:-2].decode()


@pytest.fixture
def fake_server():
    """A one-connection RCON server. Password 'pw'; echoes 'ran: <cmd>'."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)

    def serve():
        conn, _ = srv.accept()
        with conn:
            req_id, kind, body = _read_packet(conn)
            assert kind == 3
            conn.sendall(_packet(req_id if body == "pw" else -1, 2, ""))
            if body != "pw":
                return
            while True:
                try:
                    req_id, kind, body = _read_packet(conn)
                except (struct.error, ConnectionError):
                    return
                reply = "There are 2 of a max of 20 players online: a, b" if body == "list" else f"ran: {body}"
                conn.sendall(_packet(req_id, 0, reply))

    threading.Thread(target=serve, daemon=True).start()
    yield srv.getsockname()[1]
    srv.close()


def test_command_round_trip(fake_server):
    with Rcon("127.0.0.1", fake_server, "pw") as rcon:
        assert rcon.command("say hi") == "ran: say hi"


def test_bad_password_raises(fake_server):
    with pytest.raises(RconError, match="authentication"):
        with Rcon("127.0.0.1", fake_server, "wrong"):
            pass


def test_connection_refused_raises_oserror():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    with pytest.raises(OSError):
        with Rcon("127.0.0.1", port, "pw", timeout=1):
            pass


@pytest.mark.parametrize("text,expected", [
    ("There are 0 of a max of 20 players online: ", 0),
    ("There are 3 of a max of 20 players online: a, b, c", 3),
    ("§6There are §c1§6 of a max of §c20§6 players online:", 1),
])
def test_player_count(text, expected):
    assert player_count(text) == expected


def test_player_count_rejects_garbage():
    with pytest.raises(RconError):
        player_count("Unknown command")
```

`server/lib/tests/test_players.py`:
```python
import pytest

from players import PlayersError, commands_for, parse_players


def test_ops_are_whitelisted_and_sorted():
    p = parse_players('{"ops": ["Dad"], "whitelist": ["Kid_2", "Kid1"]}')
    assert p == {"ops": ["Dad"], "whitelist": ["Dad", "Kid1", "Kid_2"]}


def test_commands():
    assert commands_for({"ops": ["Dad"], "whitelist": ["Dad", "Kid1"]}) == [
        "whitelist add Dad",
        "whitelist add Kid1",
        "op Dad",
    ]


def test_missing_keys_mean_empty():
    assert parse_players("{}") == {"ops": [], "whitelist": []}


@pytest.mark.parametrize("bad", [
    '{"whitelist": ["bob; op mallory"]}',
    '{"whitelist": ["ab"]}',
    '{"whitelist": ["a_very_long_name_17"]}',
    '{"ops": "Dad"}',
    '{"whitelist": [42]}',
    'not json',
])
def test_rejects_injection_in_name(bad):
    with pytest.raises(PlayersError):
        parse_players(bad)
```

`server/lib/tests/test_jars.py`:
```python
import hashlib
import io

import pytest

from jars import ensure_file, sync_jars


def opener_for(content: bytes, calls: list):
    def opener(url):
        calls.append(url)
        return io.BytesIO(content)
    return opener


def sha(b):
    return hashlib.sha256(b).hexdigest()


def test_downloads_when_missing(tmp_path):
    calls = []
    dest = tmp_path / "paper.jar"
    assert ensure_file("u", sha(b"jar"), str(dest), opener_for(b"jar", calls)) is True
    assert dest.read_bytes() == b"jar" and calls == ["u"]


def test_skips_when_checksum_matches(tmp_path):
    calls = []
    dest = tmp_path / "paper.jar"
    dest.write_bytes(b"jar")
    assert ensure_file("u", sha(b"jar"), str(dest), opener_for(b"jar", calls)) is False
    assert calls == []


def test_checksum_mismatch_raises_and_keeps_old_file(tmp_path):
    dest = tmp_path / "paper.jar"
    dest.write_bytes(b"old")
    with pytest.raises(ValueError, match="checksum"):
        ensure_file("u", sha(b"expected"), str(dest), opener_for(b"tampered", []))
    assert dest.read_bytes() == b"old"


def test_sync_removes_unlisted_plugin_jars(tmp_path):
    plugins = tmp_path / "plugins"
    plugins.mkdir()
    (plugins / "old-plugin.jar").write_bytes(b"x")
    (plugins / "data.yml").write_text("keep")
    manifest = {
        "paper": {"url": "p", "sha256": sha(b"P")},
        "plugins": [{"file": "squaremap.jar", "url": "s", "sha256": sha(b"S")}],
    }
    content = {"p": b"P", "s": b"S"}
    sync_jars(manifest, str(tmp_path), opener=lambda u: io.BytesIO(content[u]))
    assert sorted(f.name for f in plugins.iterdir()) == ["data.yml", "squaremap.jar"]
    assert (tmp_path / "paper.jar").read_bytes() == b"P"
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest server/lib/tests -q`
Expected: FAIL with `ModuleNotFoundError` for `mcrcon`, `players`, `jars`.

- [ ] **Step 3: Implement** — `server/lib/mcrcon.py`

```python
"""Minimal Source RCON client (as used by Minecraft) plus output parsing."""
import re
import socket
import struct

_LOGIN, _COMMAND = 3, 2
_PLAYERS = re.compile(r"There are (\d+)")
_COLOUR = re.compile("§.")


class RconError(Exception):
    pass


class Rcon:
    def __init__(self, host: str, port: int, password: str, timeout: float = 10):
        self._addr = (host, port)
        self._password = password
        self._timeout = timeout
        self._sock = None
        self._next_id = 0

    def __enter__(self):
        self._sock = socket.create_connection(self._addr, timeout=self._timeout)
        req_id = self._send(_LOGIN, self._password)
        resp_id, _, _ = self._recv()
        if resp_id == -1 or resp_id != req_id:
            self._sock.close()
            raise RconError("authentication failed")
        return self

    def __exit__(self, *exc):
        self._sock.close()

    def command(self, cmd: str) -> str:
        self._send(_COMMAND, cmd)
        _, _, body = self._recv()
        return body

    def _send(self, kind: int, body: str) -> int:
        self._next_id += 1
        data = struct.pack("<ii", self._next_id, kind) + body.encode("utf-8") + b"\x00\x00"
        self._sock.sendall(struct.pack("<i", len(data)) + data)
        return self._next_id

    def _recv(self):
        (length,) = struct.unpack("<i", self._read(4))
        data = self._read(length)
        req_id, kind = struct.unpack("<ii", data[:8])
        return req_id, kind, data[8:-2].decode("utf-8", "replace")

    def _read(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connection closed")
            buf += chunk
        return buf


def player_count(list_output: str) -> int:
    match = _PLAYERS.search(_COLOUR.sub("", list_output))
    if not match:
        raise RconError(f"unexpected list output: {list_output!r}")
    return int(match.group(1))
```

`server/lib/players.py`:
```python
"""Validate the /minecraft/players JSON and turn it into RCON commands."""
import json
import re
import sys

_NAME = re.compile(r"^[A-Za-z0-9_]{3,16}$")


class PlayersError(ValueError):
    pass


def _names(data: dict, key: str) -> list[str]:
    value = data.get(key, [])
    if not isinstance(value, list):
        raise PlayersError(f"{key} must be a list")
    for name in value:
        if not isinstance(name, str) or not _NAME.match(name):
            raise PlayersError(f"invalid Minecraft username in {key}: {name!r}")
    return value


def parse_players(text: str) -> dict:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise PlayersError(f"not valid JSON: {e}") from e
    if not isinstance(data, dict):
        raise PlayersError("top level must be an object")
    ops = sorted(set(_names(data, "ops")))
    whitelist = sorted(set(_names(data, "whitelist")) | set(ops))
    return {"ops": ops, "whitelist": whitelist}


def commands_for(players: dict) -> list[str]:
    return [f"whitelist add {n}" for n in players["whitelist"]] + [f"op {n}" for n in players["ops"]]


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "--validate":
        sys.exit("usage: players.py --validate FILE")
    try:
        with open(sys.argv[2]) as f:
            print(parse_players(f.read()))
    except (OSError, PlayersError) as e:
        sys.exit(f"invalid players file: {e}")
```

`server/lib/jars.py`:
```python
"""Download jars and verify their SHA-256 checksums."""
import hashlib
import os
import tempfile
import urllib.request


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_file(url: str, sha256: str, dest: str, opener=urllib.request.urlopen) -> bool:
    if os.path.exists(dest) and _sha256_file(dest) == sha256:
        return False
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest) or ".", suffix=".part")
    try:
        with os.fdopen(fd, "wb") as out, opener(url) as resp:
            for chunk in iter(lambda: resp.read(1 << 20), b""):
                out.write(chunk)
        actual = _sha256_file(tmp)
        if actual != sha256:
            raise ValueError(f"checksum mismatch for {url}: expected {sha256}, got {actual}")
        os.replace(tmp, dest)
        return True
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def sync_jars(manifest: dict, mc_home: str, opener=urllib.request.urlopen) -> None:
    paper = manifest["paper"]
    ensure_file(paper["url"], paper["sha256"], os.path.join(mc_home, "paper.jar"), opener)
    plugins_dir = os.path.join(mc_home, "plugins")
    os.makedirs(plugins_dir, exist_ok=True)
    wanted = set()
    for plugin in manifest["plugins"]:
        wanted.add(plugin["file"])
        ensure_file(plugin["url"], plugin["sha256"], os.path.join(plugins_dir, plugin["file"]), opener)
    for name in os.listdir(plugins_dir):
        if name.endswith(".jar") and name not in wanted:
            os.remove(os.path.join(plugins_dir, name))
```

`server/bin/mc-rcon`:
```python
#!/usr/bin/env python3
"""Send an RCON command to the local Minecraft server. Exit 1 on any failure."""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))
from mcrcon import Rcon, RconError, player_count  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=25575)
    parser.add_argument("--password-file", default="/etc/minecraft/rcon.pass")
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--player-count", action="store_true", help="print the online player count")
    parser.add_argument("command", nargs="*")
    args = parser.parse_args()
    if not args.player_count and not args.command:
        parser.error("a command or --player-count is required")
    try:
        with open(args.password_file) as f:
            password = f.read().strip()
        with Rcon(args.host, args.port, password, args.timeout) as rcon:
            if args.player_count:
                print(player_count(rcon.command("list")))
            else:
                print(rcon.command(" ".join(args.command)))
    except (OSError, RconError) as e:
        print(f"mc-rcon: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

`server/bin/mc-apply-players`:
```python
#!/usr/bin/env python3
"""Apply players JSON (stdin) to the running server via RCON. Waits up to 300 s for RCON."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))
from mcrcon import Rcon, RconError  # noqa: E402
from players import PlayersError, commands_for, parse_players  # noqa: E402


def main() -> int:
    try:
        players = parse_players(sys.stdin.read() or "{}")
    except PlayersError as e:
        print(f"mc-apply-players: refusing players file: {e}", file=sys.stderr)
        return 1
    with open("/etc/minecraft/rcon.pass") as f:
        password = f.read().strip()
    deadline = time.monotonic() + 300
    while True:
        try:
            with Rcon("127.0.0.1", 25575, password) as rcon:
                for cmd in commands_for(players):
                    print(f"{cmd}: {rcon.command(cmd)}")
            return 0
        except (OSError, RconError) as e:
            if time.monotonic() > deadline:
                print(f"mc-apply-players: RCON never became ready: {e}", file=sys.stderr)
                return 1
            time.sleep(5)


if __name__ == "__main__":
    sys.exit(main())
```

`server/bin/mc-fetch-jars`:
```python
#!/usr/bin/env python3
"""Ensure paper.jar and plugin jars match versions.json."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))
from jars import sync_jars  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: mc-fetch-jars VERSIONS_JSON MC_HOME")
    with open(sys.argv[1]) as f:
        sync_jars(json.load(f), sys.argv[2])
```

`server/config/versions.json`:
```json
{
  "paper": {
    "version": "26.2",
    "build": 129,
    "url": "https://fill-data.papermc.io/v1/objects/b1d8f6bfa1b6101fa8e947b53041cb3bdf5540e7b83b6547ca19ba7edefeb083/paper-26.2-129.jar",
    "sha256": "b1d8f6bfa1b6101fa8e947b53041cb3bdf5540e7b83b6547ca19ba7edefeb083"
  },
  "plugins": [
    {
      "name": "squaremap",
      "file": "squaremap-paper-mc26.2-1.3.15.jar",
      "url": "https://cdn.modrinth.com/data/PFb7ZqK6/versions/ejPk2ZiR/squaremap-paper-mc26.2-1.3.15.jar",
      "sha256": "68a4ecbcac39f83b9f974aab9d624a3a07001fae4982cc358ebfab73b49885af"
    }
  ]
}
```

`scripts/players.example.json`:
```json
{"ops": ["YourName"], "whitelist": ["YourName", "FamilyMember1", "FamilyMember2"]}
```

- [ ] **Step 4: Run tests and check the real checksums**

Run: `python3 -m pytest server/lib/tests -q && chmod +x server/bin/mc-rcon server/bin/mc-apply-players server/bin/mc-fetch-jars && server/bin/mc-fetch-jars server/config/versions.json "$(mktemp -d)" && echo JARS_OK`
Expected: all tests pass, then `JARS_OK`. This downloads the real jars and confirms both pinned checksums.

- [ ] **Step 5: Commit**

```bash
git add server/lib server/bin/mc-rcon server/bin/mc-apply-players server/bin/mc-fetch-jars server/config/versions.json scripts/players.example.json
git commit -m "feat: RCON client, player list validation, checksum-verified jar fetcher"
```

---

### Task 3: Waker Lambda

**Files:**
- Create: `lambda/waker/handler.py`, `lambda/waker/tests/test_handler.py`

**Interfaces:**
- Consumes env: `INSTANCE_ID`, `INSTANCE_REGION`, `MAINTENANCE_PARAM`, `WAKE_NAMES` (comma-separated).
- Produces:
  - `handler.handler(event, context) -> {"result": str}`
  - `handler.query_name(message) -> str | None`
  - `handler.wake(ec2, ssm, instance_id, maintenance_param) -> str`, returning one of `maintenance`, `started`, `race`, `already-<state>`.

- [ ] **Step 1: Write the failing tests** — `lambda/waker/tests/test_handler.py`

```python
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
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pip install --quiet pytest boto3 && python3 -m pytest lambda/waker/tests -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'handler'`

- [ ] **Step 3: Implement** — `lambda/waker/handler.py`

```python
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
```

- [ ] **Step 4: Run tests**

Run: `python3 -m pytest lambda/waker/tests -q`
Expected: all pass (17 tests).

- [ ] **Step 5: Commit**

```bash
git add lambda/waker
git commit -m "feat: waker Lambda that starts the instance on DNS lookups"
```

---

### Task 4: Idle check, shutdown, stop-wait and backup scripts

**Files:**
- Create: `server/bin/mc-idle-check.sh`, `server/bin/mc-shutdown.sh`, `server/bin/mc-stop-wait.sh`, `server/bin/mc-backup.sh`, `server/bin/mc-map-sync.sh`
- Create: `server/tests/test_idle_check.py`, `server/tests/test_shutdown.py`

**Interfaces:**
- Consumes: `mc-rcon` (Task 2), `mc-gfs-keys` (Task 1), `/etc/minecraft.env` (Task 7, provides `MC_REGION`, `MC_BACKUP_BUCKET`, `MC_MAP_BUCKET`).
- Test seams (environment overrides): `MC_BIN` (directory holding the helper scripts), `MC_POWEROFF` (command to run instead of `systemctl poweroff`), `MC_RCON_RETRY_DELAY` (seconds between retries).
- Produces: `mc-shutdown.sh` (no arguments; deploys call it through SSM), `mc-backup.sh`, `mc-map-sync.sh`, `mc-stop-wait.sh <pid>`.

- [ ] **Step 1: Write failing tests** — `server/tests/test_idle_check.py`

```python
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
```

`server/tests/test_shutdown.py`:
```python
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
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest server/tests -q`
Expected: FAIL (the scripts don't exist yet; bash exits 127 and the assertions fail).

- [ ] **Step 3: Implement scripts**

`server/bin/mc-idle-check.sh`:
```bash
#!/bin/bash
# Shut the instance down when nobody is online (run every 30 min by mc-idle-check.timer).
set -uo pipefail
BIN=${MC_BIN:-/opt/minecraft/bin}
RETRY_DELAY=${MC_RCON_RETRY_DELAY:-10}

if ! systemctl is-active --quiet minecraft.service; then
  echo "minecraft.service is not active; shutting down"
  exec "$BIN/mc-shutdown.sh"
fi

count=""
for attempt in 1 2 3; do
  if count=$("$BIN/mc-rcon" --player-count) && [[ $count =~ ^[0-9]+$ ]]; then
    break
  fi
  count=""
  echo "RCON attempt $attempt failed"
  [[ $attempt -lt 3 ]] && sleep "$RETRY_DELAY"
done

if [[ -z $count ]]; then
  echo "RCON unreachable after 3 attempts; shutting down"
  exec "$BIN/mc-shutdown.sh"
fi

if (( count > 0 )); then
  echo "$count player(s) online; staying up"
  exit 0
fi

echo "no players online; shutting down"
exec "$BIN/mc-shutdown.sh"
```

`server/bin/mc-shutdown.sh`:
```bash
#!/bin/bash
# Back up, sync the map, then power off (instance stops). Used by idle check and deploys.
set -uo pipefail
BIN=${MC_BIN:-/opt/minecraft/bin}

"$BIN/mc-backup.sh" || echo "WARN: backup failed; powering off anyway" >&2
"$BIN/mc-map-sync.sh" || echo "WARN: map sync failed; powering off anyway" >&2
eval "${MC_POWEROFF:-systemctl poweroff}"
```

`server/bin/mc-stop-wait.sh`:
```bash
#!/bin/bash
# ExecStop for minecraft.service: ask Paper to stop, then wait for the JVM to exit.
# (systemd SIGTERMs remaining processes as soon as ExecStop returns, so we must wait here.)
set -uo pipefail
pid=${1:?usage: mc-stop-wait.sh PID}
/opt/minecraft/bin/mc-rcon stop || exit 0   # RCON down: let systemd's SIGTERM handle it
while kill -0 "$pid" 2>/dev/null; do
  sleep 1
done
```

`server/bin/mc-backup.sh`:
```bash
#!/bin/bash
# Archive the server directory and upload it to S3 using GFS keys.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
BIN=${MC_BIN:-/opt/minecraft/bin}
MC_HOME=${MC_HOME:-/srv/minecraft}
export AWS_REGION="$MC_REGION"

exec 9>/run/mc-backup.lock
flock 9

archive=$(mktemp /var/tmp/mc-backup.XXXXXX.tar.zst)
saving_paused=0
cleanup() {
  if (( saving_paused )); then "$BIN/mc-rcon" save-on >/dev/null 2>&1 || true; fi
  rm -f "$archive"
}
trap cleanup EXIT

if "$BIN/mc-rcon" save-off >/dev/null 2>&1; then
  saving_paused=1
  "$BIN/mc-rcon" save-all flush >/dev/null
else
  echo "RCON unavailable; archiving files as they are"
fi

tar -C "$MC_HOME" \
  --exclude=./logs --exclude=./cache --exclude=./libraries --exclude=./versions \
  --exclude=./paper.jar --exclude='./plugins/*.jar' --exclude=./plugins/.paper-remapped \
  --exclude=./plugins/squaremap/web \
  -cf - . | zstd -q -T0 -10 -f -o "$archive"

if (( saving_paused )); then
  "$BIN/mc-rcon" save-on >/dev/null || true
  saving_paused=0
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
existing=$(
  for prefix in father/ grandfather/; do
    aws s3api list-objects-v2 --bucket "$MC_BACKUP_BUCKET" --prefix "$prefix" \
      --query 'Contents[].Key' --output text
  done | tr '\t' '\n' | grep -v '^None$' || true
)
mapfile -t keys < <(printf '%s\n' "$existing" | "$BIN/mc-gfs-keys" --now "$now")

aws s3 cp --only-show-errors "$archive" "s3://$MC_BACKUP_BUCKET/${keys[0]}"
for key in "${keys[@]:1}"; do
  aws s3 cp --only-show-errors "s3://$MC_BACKUP_BUCKET/${keys[0]}" "s3://$MC_BACKUP_BUCKET/$key"
done
echo "backup written: ${keys[*]}"
```

`server/bin/mc-map-sync.sh`:
```bash
#!/bin/bash
# Publish squaremap's static web output to the map bucket.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
MC_HOME=${MC_HOME:-/srv/minecraft}
web="$MC_HOME/plugins/squaremap/web"

if [[ ! -d $web ]]; then
  echo "no squaremap output yet; nothing to sync"
  exit 0
fi
aws s3 sync "$web" "s3://$MC_MAP_BUCKET/" --delete --only-show-errors --region "$MC_REGION"
```

- [ ] **Step 4: Run tests + shellcheck**

Run: `chmod +x server/bin/*.sh && python3 -m pytest server/tests -q && shellcheck server/bin/*.sh`
Expected: 7 passed, and no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add server/bin/*.sh server/tests
git commit -m "feat: idle check, shutdown, backup and map sync scripts"
```

---

### Task 5: Boot-time scripts, restore, systemd units, server config

**Files:**
- Create: `server/bin/mc-bootstrap.sh`, `server/bin/mc-update-dns.sh`, `server/bin/mc-restore.sh`
- Create: `server/systemd/minecraft.service`, `server/systemd/mc-idle-check.service`, `server/systemd/mc-idle-check.timer`, `server/systemd/mc-backup.service`, `server/systemd/mc-backup.timer`, `server/systemd/mc-map-sync.service`, `server/systemd/mc-map-sync.timer`
- Create: `server/config/server.properties.tmpl`, `server/config/squaremap.yml`
- Create: `scripts/set-players.sh`

**Interfaces:**
- Consumes `/etc/minecraft.env` (written by `user_data` in Task 7): `MC_REGION`, `MC_BACKUP_BUCKET`, `MC_MAP_BUCKET`, `MC_ZONE_ID`, `MC_RECORD_NAME`, `MC_PLAYERS_PARAM`, `MC_RCON_PARAM`.
- Consumes the Task 2 CLIs `mc-fetch-jars` and `mc-apply-players`.
- Produces: `/opt/minecraft/bin/mc-bootstrap.sh`, which `mc-bootstrap.service` (installed by user_data) runs on every boot after the `config/` sync.

- [ ] **Step 1: Write the scripts**

`server/bin/mc-bootstrap.sh`:
```bash
#!/bin/bash
# Every boot: install packages, render config, fetch jars, update DNS, start Paper + timers.
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
OPT=/opt/minecraft
MC_HOME=/srv/minecraft
export AWS_REGION="$MC_REGION"

param() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text; }

rpm -q java-25-amazon-corretto-headless zstd python3 >/dev/null 2>&1 \
  || dnf install -y java-25-amazon-corretto-headless zstd python3

id minecraft >/dev/null 2>&1 || useradd --system --home-dir "$MC_HOME" --shell /sbin/nologin minecraft
install -d -o minecraft -g minecraft "$MC_HOME" "$MC_HOME/plugins" "$MC_HOME/plugins/squaremap"
install -d -m 750 -o root -g minecraft /etc/minecraft

rcon_password=$(param "$MC_RCON_PARAM")
install -m 640 -o root -g minecraft /dev/null /etc/minecraft/rcon.pass
printf '%s' "$rcon_password" > /etc/minecraft/rcon.pass

"$OPT/bin/mc-fetch-jars" "$OPT/config/versions.json" "$MC_HOME"
sed "s|@RCON_PASSWORD@|${rcon_password}|" "$OPT/config/server.properties.tmpl" > "$MC_HOME/server.properties"
cp "$OPT/config/squaremap.yml" "$MC_HOME/plugins/squaremap/config.yml"
echo "eula=true" > "$MC_HOME/eula.txt"
# SSM /minecraft/players is the source of truth: start empty, then add via RCON (resolves UUIDs).
echo '[]' > "$MC_HOME/whitelist.json"
echo '[]' > "$MC_HOME/ops.json"
chown -R minecraft:minecraft "$MC_HOME"

cp "$OPT"/systemd/* /etc/systemd/system/
systemctl daemon-reload

"$OPT/bin/mc-update-dns.sh"
systemctl start minecraft.service mc-idle-check.timer mc-backup.timer mc-map-sync.timer

players=$(param "$MC_PLAYERS_PARAM" 2>/dev/null || echo '{}')
printf '%s' "$players" | "$OPT/bin/mc-apply-players"
```

`server/bin/mc-update-dns.sh`:
```bash
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
```

`server/bin/mc-restore.sh`:
```bash
#!/bin/bash
# Restore a backup: mc-restore.sh <s3-key>, e.g. father/2026-W40.tar.zst
set -euo pipefail
# shellcheck source=/dev/null
source /etc/minecraft.env
key=${1:?usage: mc-restore.sh S3_KEY}
MC_HOME=/srv/minecraft
stamp=$(date -u +%Y%m%dT%H%M%SZ)
aside="$MC_HOME/restore-backup-$stamp"
archive=$(mktemp /var/tmp/mc-restore.XXXXXX.tar.zst)
trap 'rm -f "$archive"' EXIT

aws s3 cp --only-show-errors --region "$MC_REGION" "s3://$MC_BACKUP_BUCKET/$key" "$archive"
systemctl stop minecraft.service
mkdir -p "$aside"
for dir in world world_nether world_the_end; do
  if [[ -e $MC_HOME/$dir ]]; then mv "$MC_HOME/$dir" "$aside/"; fi
done
zstd -dc "$archive" | tar -C "$MC_HOME" -xf -
chown -R minecraft:minecraft "$MC_HOME"
systemctl start minecraft.service
echo "restored $key; previous world kept in $aside"
```

`scripts/set-players.sh`:
```bash
#!/bin/bash
# Upload the family player list to SSM. Usage: scripts/set-players.sh players.json
set -euo pipefail
file=${1:?usage: scripts/set-players.sh players.json (see scripts/players.example.json)}
here=$(cd "$(dirname "$0")" && pwd)
python3 "$here/../server/lib/players.py" --validate "$file"
aws ssm put-parameter --profile "${AWS_PROFILE_NAME:-dosaki}" --region eu-west-1 \
  --name /minecraft/players --type SecureString --overwrite --value "file://$file" >/dev/null
echo "Players updated. They apply the next time the server boots."
```

- [ ] **Step 2: Write systemd units**

`server/systemd/minecraft.service`:
```ini
[Unit]
Description=Paper Minecraft server
After=network-online.target
Wants=network-online.target

[Service]
User=minecraft
Group=minecraft
WorkingDirectory=/srv/minecraft
ExecStart=/usr/bin/java -Xms12G -Xmx12G -XX:+AlwaysPreTouch -XX:+DisableExplicitGC -XX:+ParallelRefProcEnabled -XX:+PerfDisableSharedMem -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1HeapRegionSize=8M -XX:G1HeapWastePercent=5 -XX:G1MaxNewSizePercent=40 -XX:G1MixedGCCountTarget=4 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1NewSizePercent=30 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15 -XX:MaxGCPauseMillis=200 -XX:MaxTenuringThreshold=1 -XX:SurvivorRatio=32 -jar paper.jar --nogui
ExecStop=/opt/minecraft/bin/mc-stop-wait.sh $MAINPID
TimeoutStopSec=120
SuccessExitStatus=0 143
Restart=on-failure
RestartSec=10
```

`server/systemd/mc-idle-check.service`:
```ini
[Unit]
Description=Stop the instance if no players are online

[Service]
Type=oneshot
ExecStart=/opt/minecraft/bin/mc-idle-check.sh
```

`server/systemd/mc-idle-check.timer`:
```ini
[Unit]
Description=Idle check every 30 minutes

[Timer]
OnBootSec=30min
OnUnitActiveSec=30min
```

`server/systemd/mc-backup.service`:
```ini
[Unit]
Description=Back up the world to S3 (GFS)

[Service]
Type=oneshot
ExecStart=/opt/minecraft/bin/mc-backup.sh
```

`server/systemd/mc-backup.timer`:
```ini
[Unit]
Description=Hourly world backup while running

[Timer]
OnBootSec=60min
OnUnitActiveSec=60min
```

`server/systemd/mc-map-sync.service`:
```ini
[Unit]
Description=Sync squaremap tiles to S3

[Service]
Type=oneshot
ExecStart=/opt/minecraft/bin/mc-map-sync.sh
```

`server/systemd/mc-map-sync.timer`:
```ini
[Unit]
Description=Map sync every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
```

- [ ] **Step 3: Write config**

`server/config/server.properties.tmpl`:
```properties
motd=Dosaki family server
difficulty=normal
gamemode=survival
max-players=20
view-distance=10
simulation-distance=10
online-mode=true
white-list=true
enforce-whitelist=true
spawn-protection=0
server-port=25565
enable-query=false
enable-rcon=true
rcon.port=25575
rcon.password=@RCON_PASSWORD@
broadcast-rcon-to-ops=false
```

`server/config/squaremap.yml`:
```yaml
settings:
  web-directory:
    path: web
  internal-webserver:
    enabled: false
```

- [ ] **Step 4: Lint and run the full test suite**

Run: `chmod +x server/bin/*.sh scripts/*.sh && shellcheck server/bin/*.sh scripts/*.sh && python3 -m pytest -q && (python3 server/lib/players.py --validate scripts/players.example.json)`
Expected: shellcheck silent, all tests pass, validate prints the parsed dict.

- [ ] **Step 5: Commit**

```bash
git add server scripts/set-players.sh
git commit -m "feat: boot, DNS update, restore scripts; systemd units; server config"
```

---

### Task 6: CI stop-server script (used by deploy)

**Files:**
- Create: `scripts/ci-stop-server.sh`, `server/tests/test_ci_stop_server.py`

**Interfaces:**
- Consumes: the `aws` CLI (credentials from OIDC in CI); `/opt/minecraft/bin/mc-rcon` and `mc-shutdown.sh` on the instance via SSM.
- Produces: `scripts/ci-stop-server.sh [INSTANCE_ID]`. Exits 0 once the instance is stopped, or when there's nothing to stop. Exits non-zero if the instance won't stop within the waiter limit.
- Test seams: `WARN_FIRST_SECONDS` (default 240), `WARN_SECOND_SECONDS` (default 60).

- [ ] **Step 1: Write failing tests** — `server/tests/test_ci_stop_server.py`

```python
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
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m pytest server/tests/test_ci_stop_server.py -q`
Expected: FAIL (the script doesn't exist).

- [ ] **Step 3: Implement** — `scripts/ci-stop-server.sh`

```bash
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
```

- [ ] **Step 4: Run tests + shellcheck**

Run: `chmod +x scripts/ci-stop-server.sh && python3 -m pytest -q && shellcheck scripts/*.sh server/bin/*.sh`
Expected: all tests pass; shellcheck silent.

- [ ] **Step 5: Commit**

```bash
git add scripts/ci-stop-server.sh server/tests/test_ci_stop_server.py
git commit -m "feat: deploy helper that warns players and stops the instance"
```

---

### Task 7: Terraform bootstrap (state bucket, OIDC, CI roles)

**Files:**
- Create: `bootstrap/main.tf`

**Interfaces:**
- Produces: S3 bucket `dosaki-minecraft-tfstate`; roles `gha-minecraft-deploy` and `gha-minecraft-plan` (outputs `deploy_role_arn`, `plan_role_arn`).

- [ ] **Step 1: Write** `bootstrap/main.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # After the first apply, uncomment and run `terraform init -migrate-state -backend-config="profile=dosaki"`.
  # backend "s3" {
  #   bucket       = "dosaki-minecraft-tfstate"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "eu-west-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

variable "aws_profile" {
  type    = string
  default = "dosaki"
}

variable "github_repo" {
  type    = string
  default = "dosaki/minecraft-server"
}

provider "aws" {
  region  = "eu-west-1"
  profile = var.aws_profile == "" ? null : var.aws_profile
  default_tags {
    tags = { Project = "minecraft-server" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  buckets = ["dosaki-minecraft-tfstate", "dosaki-minecraft-backups", "dosaki-minecraft-map"]
}

resource "aws_s3_bucket" "state" {
  bucket = "dosaki-minecraft-tfstate"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:pull_request",
        "repo:${var.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "gha-minecraft-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
}

resource "aws_iam_role" "plan" {
  name               = "gha-minecraft-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "Ec2InHomeRegion"
    actions   = ["ec2:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["eu-west-1"]
    }
  }
  statement {
    sid = "GlobalAndEdgeServices"
    actions = [
      "route53:*", "cloudfront:*", "acm:*", "budgets:*", "logs:*",
      "sts:GetCallerIdentity", "tag:GetResources",
      "ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation", "ssm:DescribeParameters",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "Lambda"
    actions = ["lambda:*"]
    resources = [
      "arn:aws:lambda:us-east-1:${local.account}:function:minecraft-server-*",
    ]
  }
  statement {
    sid     = "SsmParameters"
    actions = ["ssm:*"]
    resources = [
      "arn:aws:ssm:eu-west-1:${local.account}:parameter/minecraft/*",
      "arn:aws:ssm:eu-west-1::parameter/aws/service/*",
    ]
  }
  statement {
    sid       = "Buckets"
    actions   = ["s3:*"]
    resources = flatten([for b in local.buckets : ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"]])
  }
  statement {
    sid     = "StackIam"
    actions = ["iam:*"]
    resources = [
      "arn:aws:iam::${local.account}:role/minecraft-server-*",
      "arn:aws:iam::${local.account}:instance-profile/minecraft-server-*",
      "arn:aws:iam::${local.account}:policy/minecraft-server-*",
    ]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
output "plan_role_arn" { value = aws_iam_role.plan.arn }
```

- [ ] **Step 2: Validate offline**

Run: `cd bootstrap && terraform init -backend=false && terraform validate && terraform fmt -check && cd ..`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit** (applying it happens in Task 11, with the user's go-ahead)

```bash
git add bootstrap/main.tf
git commit -m "feat: bootstrap stack for state bucket and GitHub OIDC roles"
```

---

### Task 8: Main stack — providers, DNS, waker

**Files:**
- Create: `terraform/providers.tf`, `terraform/backend.tf`, `terraform/variables.tf`, `terraform/locals.tf`, `terraform/dns.tf`, `terraform/waker.tf`

**Interfaces:**
- Consumes: `lambda/waker/handler.py`; `aws_instance.mc.id` (Task 9).
- Produces: `aws_route53_zone.mc`, `aws_ssm_parameter.maintenance`, `local.fqdn`, `local.map_fqdn`, `local.account`, and the `aws.us_east_1` provider alias.

- [ ] **Step 1: Write the files**

`terraform/providers.tf`:
```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile == "" ? null : var.aws_profile
  default_tags {
    tags = { Project = "minecraft-server" }
  }
}

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile == "" ? null : var.aws_profile
  default_tags {
    tags = { Project = "minecraft-server" }
  }
}
```

`terraform/backend.tf`:
```hcl
# Locally: terraform init -backend-config="profile=dosaki"
terraform {
  backend "s3" {
    bucket       = "dosaki-minecraft-tfstate"
    key          = "main/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

`terraform/variables.tf`:
```hcl
variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile. CI sets this to \"\" and uses OIDC credentials."
  type        = string
  default     = "dosaki"
}

variable "parent_domain" {
  type    = string
  default = "dosaki.net"
}

variable "server_label" {
  type    = string
  default = "minecraft"
}

variable "instance_type" {
  type    = string
  default = "m7g.xlarge"
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "backup_bucket" {
  type    = string
  default = "dosaki-minecraft-backups"
}

variable "map_bucket" {
  type    = string
  default = "dosaki-minecraft-map"
}

variable "budget_limit_usd" {
  type    = number
  default = 20
}

variable "budget_email" {
  type      = string
  sensitive = true
}
```

`terraform/locals.tf`:
```hcl
data "aws_caller_identity" "current" {}

locals {
  account  = data.aws_caller_identity.current.account_id
  fqdn     = "${var.server_label}.${var.parent_domain}"
  map_fqdn = "map.${local.fqdn}"
}
```

`terraform/dns.tf`:
```hcl
data "aws_route53_zone" "parent" {
  name         = var.parent_domain
  private_zone = false
}

resource "aws_route53_zone" "mc" {
  name = local.fqdn
}

resource "aws_route53_record" "delegation" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = local.fqdn
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.mc.name_servers
}

# The instance UPSERTs its own IP on every boot; Terraform only creates the record.
resource "aws_route53_record" "server" {
  zone_id = aws_route53_zone.mc.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 30
  records = ["192.0.2.1"]
  lifecycle {
    ignore_changes = [records]
  }
}
```

`terraform/waker.tf`:
```hcl
resource "aws_ssm_parameter" "maintenance" {
  name  = "/minecraft/maintenance"
  type  = "String"
  value = "false"
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_cloudwatch_log_group" "dns_queries" {
  provider          = aws.us_east_1
  name              = "/aws/route53/${local.fqdn}"
  retention_in_days = 3
}

data "aws_iam_policy_document" "route53_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:us-east-1:${local.account}:log-group:/aws/route53/*"]
    principals {
      type        = "Service"
      identifiers = ["route53.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "route53" {
  provider        = aws.us_east_1
  policy_name     = "minecraft-server-route53-query-logging"
  policy_document = data.aws_iam_policy_document.route53_logs.json
}

resource "aws_route53_query_log" "mc" {
  depends_on               = [aws_cloudwatch_log_resource_policy.route53]
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.dns_queries.arn
  zone_id                  = aws_route53_zone.mc.zone_id
}

data "archive_file" "waker" {
  type        = "zip"
  source_file = "${path.module}/../lambda/waker/handler.py"
  output_path = "${path.module}/.build/waker.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "waker" {
  name               = "minecraft-server-waker"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "waker" {
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    actions   = ["ec2:StartInstances"]
    resources = [aws_instance.mc.arn]
  }
  statement {
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.maintenance.arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waker.arn}:*"]
  }
}

resource "aws_iam_role_policy" "waker" {
  name   = "waker"
  role   = aws_iam_role.waker.id
  policy = data.aws_iam_policy_document.waker.json
}

resource "aws_cloudwatch_log_group" "waker" {
  provider          = aws.us_east_1
  name              = "/aws/lambda/minecraft-server-waker"
  retention_in_days = 14
}

resource "aws_lambda_function" "waker" {
  provider         = aws.us_east_1
  function_name    = "minecraft-server-waker"
  role             = aws_iam_role.waker.arn
  runtime          = "python3.13"
  handler          = "handler.handler"
  filename         = data.archive_file.waker.output_path
  source_code_hash = data.archive_file.waker.output_base64sha256
  timeout          = 30
  depends_on       = [aws_cloudwatch_log_group.waker]

  environment {
    variables = {
      INSTANCE_ID       = aws_instance.mc.id
      INSTANCE_REGION   = var.region
      MAINTENANCE_PARAM = aws_ssm_parameter.maintenance.name
      WAKE_NAMES        = join(",", [local.fqdn, "_minecraft._tcp.${local.fqdn}"])
    }
  }
}

resource "aws_lambda_permission" "logs" {
  provider      = aws.us_east_1
  statement_id  = "AllowRoute53QueryLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.waker.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.dns_queries.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "waker" {
  provider        = aws.us_east_1
  name            = "minecraft-server-waker"
  log_group_name  = aws_cloudwatch_log_group.dns_queries.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.waker.arn
  depends_on      = [aws_lambda_permission.logs]
}
```

- [ ] **Step 2: Commit** (validation happens at the end of Task 9, once `aws_instance.mc` exists)

```bash
git add terraform/providers.tf terraform/backend.tf terraform/variables.tf terraform/locals.tf terraform/dns.tf terraform/waker.tf
git commit -m "feat: terraform DNS child zone, query logging and waker Lambda"
```

---

### Task 9: Main stack — server, backups, config upload, map, budget, outputs

**Files:**
- Create: `terraform/server.tf`, `terraform/backups.tf`, `terraform/config_upload.tf`, `terraform/map.tf`, `terraform/budget.tf`, `terraform/outputs.tf`, `terraform/templates/user_data.sh.tftpl`

**Interfaces:**
- Consumes: `aws_route53_zone.mc`, `local.*` (Task 8); the `server/` directory (Tasks 1–5).
- Produces: `aws_instance.mc` and outputs `instance_id`, `map_url`, `server_address`, `backup_bucket`.

- [ ] **Step 1: Write** `terraform/templates/user_data.sh.tftpl`

```bash
#!/bin/bash
# First boot only: write environment, install the every-boot bootstrap unit.
set -euo pipefail

cat > /etc/minecraft.env <<'EOF'
MC_REGION=${region}
MC_BACKUP_BUCKET=${backup_bucket}
MC_MAP_BUCKET=${map_bucket}
MC_ZONE_ID=${zone_id}
MC_RECORD_NAME=${record_name}
MC_PLAYERS_PARAM=/minecraft/players
MC_RCON_PARAM=${rcon_param}
EOF

cat > /usr/local/sbin/mc-fetch-config <<'EOF'
#!/bin/bash
set -euo pipefail
source /etc/minecraft.env
mkdir -p /opt/minecraft
aws s3 sync "s3://$${MC_BACKUP_BUCKET}/config/" /opt/minecraft/ --delete --only-show-errors --region "$${MC_REGION}"
chmod +x /opt/minecraft/bin/*
exec /opt/minecraft/bin/mc-bootstrap.sh
EOF
chmod +x /usr/local/sbin/mc-fetch-config

cat > /etc/systemd/system/mc-bootstrap.service <<'EOF'
[Unit]
Description=Fetch Minecraft config from S3 and start the server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mc-fetch-config
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mc-bootstrap.service
```

- [ ] **Step 2: Write** `terraform/server.tf`

```hcl
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "mc" {
  name        = "minecraft-server"
  description = "Minecraft Java port only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "minecraft" {
  security_group_id = aws_security_group.mc.id
  ip_protocol       = "tcp"
  from_port         = 25565
  to_port           = 25565
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.mc.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "random_password" "rcon" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "rcon" {
  name  = "/minecraft/rcon-password"
  type  = "SecureString"
  value = random_password.rcon.result
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "minecraft-server-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn, aws_s3_bucket.map.arn]
  }
  statement {
    sid       = "ReadConfig"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/config/*"]
  }
  statement {
    sid     = "WriteBackups"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [for p in ["son", "father", "grandfather", "latest"] : "${aws_s3_bucket.backups.arn}/${p}/*"]
  }
  statement {
    sid       = "SyncMap"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.map.arn}/*"]
  }
  statement {
    sid       = "UpdateOwnDns"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.mc.arn]
  }
  statement {
    sid     = "ReadSecrets"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.rcon.arn,
      "arn:aws:ssm:${var.region}:${local.account}:parameter/minecraft/players",
    ]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "minecraft-server-instance"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "mc" {
  ami                                  = data.aws_ssm_parameter.al2023_arm64.value
  instance_type                        = var.instance_type
  subnet_id                            = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids               = [aws_security_group.mc.id]
  iam_instance_profile                 = aws_iam_instance_profile.instance.name
  associate_public_ip_address          = true
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = false # keep the world if the instance is ever replaced
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region        = var.region
    backup_bucket = aws_s3_bucket.backups.bucket
    map_bucket    = aws_s3_bucket.map.bucket
    zone_id       = aws_route53_zone.mc.zone_id
    record_name   = local.fqdn
    rcon_param    = aws_ssm_parameter.rcon.name
  })

  # Config must be in S3 before first boot.
  depends_on = [aws_s3_object.config]

  tags = { Name = "minecraft-server" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}
```

- [ ] **Step 3: Write** `terraform/backups.tf` and `terraform/config_upload.tf`

`terraform/backups.tf`:
```hcl
resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  dynamic "rule" {
    for_each = { son = 14, father = 56, grandfather = 365 }
    content {
      id     = "${rule.key}-expiry"
      status = "Enabled"
      filter {
        prefix = "${rule.key}/"
      }
      expiration {
        days = rule.value
      }
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
```

`terraform/config_upload.tf`:
```hcl
locals {
  server_dir = "${path.module}/../server"
  server_files = [
    for f in fileset(local.server_dir, "**") : f
    if !can(regex("(^|/)(tests|__pycache__)/|\\.pyc$", f))
  ]
}

resource "aws_s3_object" "config" {
  for_each = toset(local.server_files)
  bucket   = aws_s3_bucket.backups.id
  key      = "config/${each.value}"
  source   = "${local.server_dir}/${each.value}"
  etag     = filemd5("${local.server_dir}/${each.value}")
}
```

- [ ] **Step 4: Write** `terraform/map.tf`, `terraform/budget.tf`, `terraform/outputs.tf`

`terraform/map.tf`:
```hcl
resource "aws_s3_bucket" "map" {
  bucket = var.map_bucket
}

resource "aws_s3_bucket_public_access_block" "map" {
  bucket                  = aws_s3_bucket.map.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_acm_certificate" "map" {
  provider          = aws.us_east_1
  domain_name       = local.map_fqdn
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "map_validation" {
  for_each = {
    for o in aws_acm_certificate.map.domain_validation_options : o.domain_name => o
  }
  zone_id = aws_route53_zone.mc.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "map" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.map.arn
  validation_record_fqdns = [for r in aws_route53_record.map_validation : r.fqdn]
}

resource "aws_cloudfront_origin_access_control" "map" {
  name                              = "minecraft-server-map"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "map" {
  name        = "minecraft-server-map"
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 3600
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

resource "aws_cloudfront_distribution" "map" {
  enabled             = true
  is_ipv6_enabled     = true
  aliases             = [local.map_fqdn]
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "map-bucket"
    domain_name              = aws_s3_bucket.map.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.map.id
  }

  default_cache_behavior {
    target_origin_id       = "map-bucket"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.map.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.map.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

data "aws_iam_policy_document" "map_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.map.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.map.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "map" {
  bucket = aws_s3_bucket.map.id
  policy = data.aws_iam_policy_document.map_bucket.json
}

resource "aws_route53_record" "map" {
  for_each = toset(["A", "AAAA"])
  zone_id  = aws_route53_zone.mc.zone_id
  name     = local.map_fqdn
  type     = each.value
  alias {
    name                   = aws_cloudfront_distribution.map.domain_name
    zone_id                = aws_cloudfront_distribution.map.hosted_zone_id
    evaluate_target_health = false
  }
}
```

`terraform/budget.tf`:
```hcl
resource "aws_budgets_budget" "monthly" {
  name         = "minecraft-server-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
```

`terraform/outputs.tf`:
```hcl
output "instance_id" {
  value = aws_instance.mc.id
}

output "server_address" {
  value = local.fqdn
}

output "map_url" {
  value = "https://${local.map_fqdn}"
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}
```

- [ ] **Step 5: Validate offline**

Run: `cd terraform && terraform init -backend=false && terraform validate && terraform fmt -check -recursive .. && cd ..`
Expected: `Success! The configuration is valid.` and no fmt output.

- [ ] **Step 6: Commit**

```bash
git add terraform
git commit -m "feat: terraform server instance, backups, config upload, map CDN, budget"
```

---

### Task 10: GitHub Actions workflows + README

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/workflows/deploy.yml`, `README.md`

**Interfaces:**
- Consumes: repo variables `AWS_ACCOUNT_ID`, `AWS_REGION`; secret `BUDGET_EMAIL`; `scripts/ci-stop-server.sh` (Task 6); roles from Task 7.

- [ ] **Step 1: Write** `.github/workflows/ci.yml`

```yaml
name: CI
on:
  pull_request:

permissions:
  contents: read
  id-token: write

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.13"
      - run: pip install pytest boto3
      - run: python -m pytest -q
      - run: shellcheck server/bin/*.sh scripts/*.sh

  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.13.2
          terraform_wrapper: false
      - run: terraform fmt -check -recursive
      - run: terraform -chdir=bootstrap init -backend=false && terraform -chdir=bootstrap validate
      - run: terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate

  plan:
    needs: [test, terraform]
    # Fork PRs get no OIDC token; they only run tests and lint.
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    env:
      TF_VAR_aws_profile: ""
      TF_VAR_budget_email: ${{ secrets.BUDGET_EMAIL }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.13.2
          terraform_wrapper: false
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/gha-minecraft-plan
          aws-region: ${{ vars.AWS_REGION }}
      - run: terraform -chdir=terraform init -input=false
      - run: terraform -chdir=terraform plan -input=false -lock=false
```

- [ ] **Step 2: Write** `.github/workflows/deploy.yml`

```yaml
name: Deploy
on:
  push:
    branches: [main]

concurrency:
  group: deploy
  cancel-in-progress: false

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    env:
      TF_VAR_aws_profile: ""
      TF_VAR_budget_email: ${{ secrets.BUDGET_EMAIL }}
      AWS_REGION: ${{ vars.AWS_REGION }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.13.2
          terraform_wrapper: false
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/gha-minecraft-deploy
          aws-region: ${{ vars.AWS_REGION }}

      - name: Init
        run: terraform -chdir=terraform init -input=false

      - name: Plan
        id: plan
        run: |
          set +e
          terraform -chdir=terraform plan -input=false -detailed-exitcode -out=tfplan
          code=$?
          set -e
          case $code in
            0) echo "changes=false" >> "$GITHUB_OUTPUT"; echo "No changes; server untouched." ;;
            2) echo "changes=true" >> "$GITHUB_OUTPUT" ;;
            *) exit 1 ;;
          esac

      - name: Enter maintenance
        id: maintenance
        if: steps.plan.outputs.changes == 'true'
        run: aws ssm put-parameter --name /minecraft/maintenance --type String --value true --overwrite

      - name: Warn players and stop server
        if: steps.plan.outputs.changes == 'true'
        run: |
          id=$(terraform -chdir=terraform output -raw instance_id 2>/dev/null || true)
          scripts/ci-stop-server.sh "$id"

      - name: Apply
        if: steps.plan.outputs.changes == 'true'
        run: terraform -chdir=terraform apply -input=false tfplan

      - name: Exit maintenance
        if: always() && steps.maintenance.outcome == 'success'
        run: aws ssm put-parameter --name /minecraft/maintenance --type String --value false --overwrite
```

Note: on the very first deploy `/minecraft/maintenance` doesn't exist yet. `put-parameter` creates it, and Terraform's apply then adopts it. To avoid an "already exists" error, Task 11 Step 4 creates the parameter by hand, and Terraform imports it through the `import` block below.

Append to `terraform/waker.tf`:
```hcl
import {
  to = aws_ssm_parameter.maintenance
  id = "/minecraft/maintenance"
}
```

- [ ] **Step 3: Write** `README.md`

```markdown
# minecraft-server

On-demand Paper server for the family. Connect to `minecraft.dosaki.net`. The first attempt
wakes the server (about 90 s), then connect again. It stops itself when nobody has been
online for 30–60 minutes. Map: https://map.minecraft.dosaki.net

Design: `docs/superpowers/specs/2026-10-02-minecraft-on-demand-design.md`

## Common tasks

- **Change who can play:** copy `scripts/players.example.json` to `players.json` (gitignored),
  edit it, then run `scripts/set-players.sh players.json`. Takes effect on the next boot.
- **Shell on the server:** `aws ssm start-session --profile dosaki --region eu-west-1 --target <instance_id>`
- **Restore a backup:** in a session, `sudo /opt/minecraft/bin/mc-restore.sh father/2026-W40.tar.zst`
- **Deploy:** merge a PR to `main`. Players get a 5-minute warning, then the server stops and Terraform applies.
- **Tests:** `make test lint`
```

- [ ] **Step 4: Lint the workflows and run everything**

Run: `python3 -c "import yaml,sys;[yaml.safe_load(open(f)) for f in ['.github/workflows/ci.yml','.github/workflows/deploy.yml']];print('yaml ok')" && make test lint && terraform -chdir=terraform validate`
Expected: `yaml ok`, tests pass, lint is silent, the configuration is valid. If PyYAML is missing, run `pip install pyyaml` first.

- [ ] **Step 5: Commit and push the branch** (no PR yet)

```bash
git add .github README.md terraform/waker.tf
git commit -m "feat: CI and deploy workflows with player warning and maintenance flag"
git push -u origin feat/initial-implementation
```

---

### Task 11: Bootstrap AWS and GitHub, then first deploy via merge (needs the user)

This task changes real AWS resources and GitHub settings. Each step needs the user's explicit go-ahead.

- [ ] **Step 1: Apply bootstrap** (user approves the plan output first)

```bash
cd bootstrap && terraform init && terraform plan && terraform apply
```
Then uncomment the backend block and run `terraform init -migrate-state -backend-config="profile=dosaki"`. Commit the backend change.

- [ ] **Step 2: Configure GitHub** (the user supplies the budget email interactively; it is never written to a file)

```bash
gh variable set AWS_ACCOUNT_ID --repo dosaki/minecraft-server --body "$(aws sts get-caller-identity --profile dosaki --query Account --output text)"
gh variable set AWS_REGION --repo dosaki/minecraft-server --body eu-west-1
gh secret set BUDGET_EMAIL --repo dosaki/minecraft-server   # prompts for the value
```

- [ ] **Step 3: Players** (the user creates `players.json` from the example; it's gitignored)

```bash
scripts/set-players.sh players.json
```

- [ ] **Step 4: Create the maintenance flag** (so the first deploy's `put-parameter` and the Terraform import both work)

```bash
aws ssm put-parameter --profile dosaki --region eu-west-1 --name /minecraft/maintenance --type String --value false
```

- [ ] **Step 5: Open the PR, check the CI plan, merge**

```bash
gh pr create --repo dosaki/minecraft-server --base main --head feat/initial-implementation \
  --title "Initial on-demand Minecraft server" --body "Implements docs/superpowers/specs/2026-10-02-minecraft-on-demand-design.md"
gh pr checks --watch
```
Review the `plan` job output with the user, then merge. Watch with `gh run watch`. The deploy should go Plan (changes) → maintenance → "no instance exists yet" → Apply → maintenance off.

- [ ] **Step 6: Turn on branch protection for `main`** (require the `test` and `terraform` checks)

```bash
gh api -X PUT repos/dosaki/minecraft-server/branches/main/protection --input - <<'EOF'
{"required_status_checks":{"strict":true,"contexts":["test","terraform"]},"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}
EOF
```

---

### Task 12: End-to-end smoke test (with the user)

- [ ] **Step 1: Delegation and first boot.** The instance boots once at creation. Run `dig +short NS minecraft.dosaki.net` → 4 awsdns servers. Run `dig +short minecraft.dosaki.net @8.8.8.8` → the instance's public IP, not `192.0.2.1`. If bootstrap fails, open a shell through SSM and run `journalctl -u mc-bootstrap -b`, `systemctl status minecraft`. Confirm `java -version` shows 25.
- [ ] **Step 2: Join.** The user joins from a whitelisted account (allowed) and tries a non-whitelisted one (kicked with "not whitelisted"). `/op` works for the user.
- [ ] **Step 3: Idle shutdown.** Everyone leaves. In an SSM session run `sudo systemctl start mc-idle-check.service`. Expect backup objects `son/<today>`, `father/<week>`, `grandfather/<month>` and `latest/world.tar.zst` (`aws s3 ls --profile dosaki s3://dosaki-minecraft-backups --recursive`), then the instance reaches `stopped`.
- [ ] **Step 4: Map while stopped.** Before stopping in Step 3, run `sudo /opt/minecraft/bin/mc-rcon map fullrender world` once in the SSM session and let it finish, so the map has tiles. Then open `https://map.minecraft.dosaki.net`; it loads. Run `dig map.minecraft.dosaki.net @1.1.1.1` and confirm the instance stays `stopped` (check after 2 minutes).
- [ ] **Step 5: Wake.** Run `dig minecraft.dosaki.net @8.8.8.8`. Within about 60 s the instance is `pending`/`running`. Check the waker logs: `aws logs tail /aws/lambda/minecraft-server-waker --profile dosaki --region us-east-1` shows `wake result: started`. Join after about 90 s.
- [ ] **Step 6: Deploy with the server up.** While in-game, merge a trivial PR (e.g. change `motd`). See both chat warnings, the clean stop, the apply, and `/minecraft/maintenance` back to `false`. Reconnect wakes the server with the new MOTD.
- [ ] **Step 7: Record the results** in the PR or README and close out.
