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
    '{"whitelist": ["Bob\\n"]}',
    '{"ops": "Dad"}',
    '{"whitelist": [42]}',
    'not json',
])
def test_rejects_injection_in_name(bad):
    with pytest.raises(PlayersError):
        parse_players(bad)
