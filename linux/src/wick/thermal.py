"""Thermal protection, from sysfs.

Stopping too eagerly has a real cost: the laptop suspends in the middle of the build it was kept awake for. CPUs run
at 95°C under load as a matter of course, and many laptops define a "hot" trip point well below danger, so neither
of those counts on its own. There are two rungs.

Critical, lid open or closed: a sensor at its critical limit, believed once that has lasted. Both places matter:
thermal zones have the trip points the kernel shuts down at, and hwmon has the CPU's own sensors, like coretemp,
where the critical limit is the point the chip throttles at.

Hot with the lid closed: a closed laptop can't shed heat through its keyboard, and in a bag or a sleeve it can't
shed it at all. By the time a sensor is critical the machine is already cooked, so with the lid closed heat counts
from further away: a sensor approaching its limit, or the battery warmer than a lithium cell should be kept. It has
to last longer too, because this is the rung that could end a build that was only ever sitting on a desk.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import time
from typing import Callable

from wick import battery, power
from wick.battery import sysfs_root

_ZONE_MARGIN_C = 3.0
_HWMON_MARGIN_C = 1.0
_ZONE_CLOSED_MARGIN_C = 8.0
_HWMON_CLOSED_MARGIN_C = 5.0
_NO_LIMIT_CEILING_C = 105.0
HOT_BATTERY_C = 45.0
_WARM_BATTERY_C = 40.0
_SUSTAINED_SECONDS = 30.0
CLOSED_SUSTAINED_SECONDS = 60.0
# Sensors report 0, -273 and 255 when they aren't really reading anything.
_PLAUSIBLE_C = (1.0, 150.0)
_ACPI_LIDS = Path("/proc/acpi/button/lid")


@dataclass(frozen=True)
class Zone:
    name: str
    temperature: float
    critical: float | None
    margin: float = _ZONE_MARGIN_C
    closed_margin: float = _ZONE_CLOSED_MARGIN_C

    @property
    def is_too_hot(self) -> bool:
        if self.critical is not None:
            return self.temperature >= self.critical - self.margin
        return self.temperature >= _NO_LIMIT_CEILING_C

    @property
    def is_hot(self) -> bool:
        """Hot enough to end a session, if the lid is closed and it lasts. Without a limit there's no telling."""
        return self.is_too_hot or (self.critical is not None and self.temperature >= self.critical - self.closed_margin)

    @property
    def is_warm(self) -> bool:
        return self.is_hot or (self.critical is not None and self.temperature >= self.critical - 2 * self.closed_margin)


def _millidegrees(path: Path) -> float | None:
    try:
        value = float(path.read_text(encoding="utf-8").strip()) / 1000.0
    except (OSError, ValueError):
        return None
    return value if _PLAUSIBLE_C[0] <= value <= _PLAUSIBLE_C[1] else None


def _text(path: Path, fallback: str) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, ValueError):
        return fallback


def zones() -> list[Zone]:
    found = []
    for zone in sorted((sysfs_root() / "class" / "thermal").glob("thermal_zone*")):
        temperature = _millidegrees(zone / "temp")
        if temperature is None:
            continue
        critical = None
        for type_file in zone.glob("trip_point_*_type"):
            if _text(type_file, "").lower() == "critical":
                critical = _millidegrees(zone / type_file.name.replace("_type", "_temp"))
        found.append(Zone(_text(zone / "type", zone.name), temperature, critical))

    for monitor in sorted((sysfs_root() / "class" / "hwmon").glob("hwmon*")):
        name = _text(monitor / "name", monitor.name)
        for sensor in sorted(monitor.glob("temp*_input")):
            temperature = _millidegrees(sensor)
            if temperature is None:
                continue
            critical = _millidegrees(monitor / sensor.name.replace("_input", "_crit"))
            found.append(Zone(name, temperature, critical, _HWMON_MARGIN_C, _HWMON_CLOSED_MARGIN_C))
    return found


def simulated_overheating() -> bool | None:
    value = os.environ.get("WICK_SIMULATE_THERMAL")
    return value.lower() in ("1", "true", "critical", "overheating") if value else None


def _acpi_lid_closed(lids: Path | None = None) -> bool | None:
    states = [_text(state, "") for state in sorted((lids or _ACPI_LIDS).glob("*/state"))]
    if not states:
        return None
    return any("closed" in state for state in states)


def lid_closed() -> bool | None:
    """None when there's no telling, as on a desktop or a laptop whose switch nothing reports. That counts as open.

    logind is the one whose opinion matters, since it's logind that would have suspended. It answers "open" for a
    machine with no lid at all, so its "open" is only believed where ACPI knows of a lid too.
    """
    simulated = os.environ.get("WICK_SIMULATE_LID", "").lower()
    if simulated in ("closed", "open"):
        return simulated == "closed"
    if power.simulated_file() is not None:
        return None
    if power.lid_closed():
        return True
    return _acpi_lid_closed()


@dataclass(frozen=True)
class Heat:
    """One look at how hot the laptop is, for `wick status`, `wick doctor` and the panels."""

    zones: tuple[Zone, ...]
    battery_temperature: float | None
    lid_closed: bool | None

    @classmethod
    def current(cls, lid: Callable[[], bool | None] = lid_closed, always_ask_lid: bool = True) -> Heat:
        """Asking logind about the lid costs a process. Something that polls only needs it once there's heat."""
        heat = cls(tuple(zones()), battery.temperature(), None)
        if not always_ask_lid and not heat.is_hot:
            return heat
        return cls(heat.zones, heat.battery_temperature, lid())

    @property
    def hottest(self) -> Zone | None:
        return max(self.zones, key=lambda zone: zone.temperature, default=None)

    @property
    def is_critical(self) -> bool:
        return any(zone.is_too_hot for zone in self.zones)

    @property
    def is_hot(self) -> bool:
        battery_is_hot = self.battery_temperature is not None and self.battery_temperature >= HOT_BATTERY_C
        return battery_is_hot or any(zone.is_hot for zone in self.zones)

    @property
    def is_warm(self) -> bool:
        battery_is_warm = self.battery_temperature is not None and self.battery_temperature >= _WARM_BATTERY_C
        return self.is_hot or battery_is_warm or any(zone.is_warm for zone in self.zones)

    @property
    def word(self) -> str:
        return "Hot" if self.is_hot else "Warm" if self.is_warm else "Cool"

    @property
    def summary(self) -> str:
        """`Cool, battery 31°C`, for a panel row."""
        if self.battery_temperature is None:
            return self.word
        return f"{self.word}, battery {self.battery_temperature:.0f}°C"

    def sentence(self, is_guarded: bool) -> str:
        """Only a session has a guard watching the heat, so only then is stopping a promise."""
        parts = [self.summary[0].lower() + self.summary[1:]]
        if self.lid_closed is not None:
            parts.append("lid closed" if self.lid_closed else "lid open")
        line = f"Heat: {', '.join(parts)}."
        if is_guarded and self.lid_closed and self.is_hot:
            line += " Wick stops if this lasts a minute."
        return line

    def to_dict(self) -> dict:
        return {"word": self.word, "batteryCelsius": self.battery_temperature, "lidClosed": self.lid_closed}


class Monitor:
    """Goes by how long it has lasted, so a spike or a bad sample doesn't end a session, however often it's asked."""

    def __init__(
        self,
        clock: Callable[[], float] = time.monotonic,
        lid: Callable[[], bool | None] = lid_closed,
    ) -> None:
        self._clock = clock
        self._lid = lid
        self._critical_since: float | None = None
        self._hot_and_closed_since: float | None = None

    def is_overheating(self) -> bool:
        simulated = simulated_overheating()
        if simulated is not None:
            return simulated
        now = self._clock()
        heat = Heat.current(self._lid, always_ask_lid=False)

        if not heat.is_critical:
            self._critical_since = None
        elif self._critical_since is None:
            self._critical_since = now
        if self._critical_since is not None and now - self._critical_since >= _SUSTAINED_SECONDS:
            return True

        if not (heat.is_hot and heat.lid_closed):
            self._hot_and_closed_since = None
            return False
        if self._hot_and_closed_since is None:
            self._hot_and_closed_since = now
        return now - self._hot_and_closed_since >= CLOSED_SUSTAINED_SECONDS
