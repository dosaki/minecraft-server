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
