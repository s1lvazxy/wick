"""Battery state from sysfs."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


# A sensor that isn't really reading reports things like 0 and 6553.5.
_PLAUSIBLE_C = (1.0, 100.0)


def sysfs_root() -> Path:
    return Path(os.environ.get("WICK_SYSFS_ROOT", "/sys"))


def _read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, ValueError):
        return None


def _read_number(path: Path) -> int | None:
    text = _read(path)
    try:
        return int(text) if text is not None else None
    except ValueError:
        return None


def laptop_batteries() -> list[Path]:
    """The supplies that are this laptop's own batteries.

    Laptops can have several (many ThinkPads have two), and names vary (BAT0, CMB0, macsmc-battery), so this goes
    by each supply's type. A wireless mouse is also a Battery, but its scope is Device.
    """
    try:
        supplies = sorted((sysfs_root() / "class" / "power_supply").iterdir())
    except OSError:
        return []
    return [
        supply
        for supply in supplies
        if _read(supply / "type") == "Battery" and (_read(supply / "scope") or "").lower() != "device"
    ]


def temperature() -> float | None:
    """The warmest battery in °C, or None. Plenty of laptops have no sensor there, or don't share it."""
    if os.environ.get("WICK_SIMULATE_POWER_FILE") and "WICK_SYSFS_ROOT" not in os.environ:
        return None
    readings = []
    for supply in laptop_batteries():
        tenths = _read_number(supply / "temp")
        if tenths is not None and _PLAUSIBLE_C[0] <= tenths / 10.0 <= _PLAUSIBLE_C[1]:
            readings.append(tenths / 10.0)
    return max(readings, default=None)


@dataclass(frozen=True)
class Battery:
    percent: int
    is_discharging: bool

    @classmethod
    def current(cls) -> Battery | None:
        """The laptop's overall charge, or None on a machine without a battery."""
        simulated = os.environ.get("WICK_SIMULATE_BATTERY")
        if simulated:
            parts = simulated.split(",")
            try:
                return cls(percent=int(parts[0]), is_discharging=parts[1:] == ["discharging"])
            except ValueError:
                pass
        elif os.environ.get("WICK_SIMULATE_POWER_FILE") and "WICK_SYSFS_ROOT" not in os.environ:
            return cls(percent=80, is_discharging=False)

        now_total = 0
        full_total = 0
        percents: list[int] = []
        discharging = False
        for supply in laptop_batteries():
            capacity = _read_number(supply / "capacity")
            now = _read_number(supply / "energy_now")
            full = _read_number(supply / "energy_full")
            if now is None or full is None:
                now = _read_number(supply / "charge_now")
                full = _read_number(supply / "charge_full")
            if full:
                now_total += now or 0
                full_total += full
            elif capacity is None:
                continue
            if capacity is not None:
                percents.append(capacity)
            discharging = discharging or (_read(supply / "status") or "").lower() == "discharging"

        if full_total > 0:
            percent = now_total * 100 // full_total
        elif percents:
            percent = sum(percents) // len(percents)
        else:
            return None
        return cls(percent=max(0, min(percent, 100)), is_discharging=discharging)
