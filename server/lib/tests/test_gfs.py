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
