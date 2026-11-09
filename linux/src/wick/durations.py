"""Duration parsing and clock formatting."""

from __future__ import annotations

import math
import re

VERSION = "0.3.0"

_LONGEST = 10 * 365 * 24 * 3600.0
_PART = re.compile(r"(\d+)(h|m|s)")
_UNITS = {"h": 3600.0, "m": 60.0, "s": 1.0}


def parse(text: str) -> float | None:
    """Accepts `90`, `90m`, `2h`, `1h30m` and `45s`. A bare number means minutes."""
    text = text.strip().lower()
    try:
        total = float(text) * 60.0
    except ValueError:
        total = 0.0
        position = 0
        while position < len(text):
            match = _PART.match(text, position)
            if match is None:
                return None
            total += float(match.group(1)) * _UNITS[match.group(2)]
            position = match.end()
    # float() also takes "inf", "nan" and "1e18", none of which fit in a timestamp.
    return total if math.isfinite(total) and 0 < total <= _LONGEST else None


def clock(interval: float) -> str:
    """`1:42:09`, or `42:09` under an hour. Stable-width enough for a countdown."""
    seconds = max(0, math.ceil(interval))
    hours, minutes, rest = seconds // 3600, seconds % 3600 // 60, seconds % 60
    return f"{hours}:{minutes:02d}:{rest:02d}" if hours else f"{minutes}:{rest:02d}"


def compact(interval: float) -> str:
    """`2h 05m`, `42m` or `<1m`. For the top bar, where a ticking second would pull the eye."""
    if interval < 60:
        return "<1m"
    minutes = math.ceil(interval / 60)
    return f"{minutes // 60}h {minutes % 60:02d}m" if minutes >= 60 else f"{minutes}m"
