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
        if not isinstance(name, str) or not _NAME.fullmatch(name):
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
