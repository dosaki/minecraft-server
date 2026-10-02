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
