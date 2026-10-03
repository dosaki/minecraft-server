import json
import re
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[1] / "config"


def test_template_points_pack_at_game_port():
    text = (CONFIG / "craftengine.yml.tmpl").read_text()
    assert 'url: "http://@RECORD_NAME@:25565/"' in text
    assert re.search(r"^    port: \"auto\"$", text, re.M)
    assert re.search(r"^    send-on-join: true$", text, re.M)
    assert re.search(r"^    kick-if-declined: true$", text, re.M)
    assert set(re.findall(r"@[A-Z_]+@", text)) == {"@RECORD_NAME@"}


def test_plugins_are_pinned_with_sha256():
    plugins = json.loads((CONFIG / "versions.json").read_text())["plugins"]
    assert "craftengine" in {p["name"] for p in plugins}
    for p in plugins:
        assert re.fullmatch(r"[0-9a-f]{64}", p["sha256"]), p["name"]
        assert p["url"].endswith(p["file"]), p["name"]
