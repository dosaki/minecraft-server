import re
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[1] / "config"


def test_one_life_required_is_a_boolean():
    text = (CONFIG / "onelife.yml").read_text()
    assert re.search(r"^one-life:\n(?:  #.*\n)*  required: (true|false)$", text, re.M)
