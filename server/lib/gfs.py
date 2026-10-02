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
