"""Session persistence and the rules for when a session ends."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum
import fcntl
import json
import os
from pathlib import Path
from typing import Any, Callable, ClassVar

from wick.battery import Battery


class EndReason(str, Enum):
    TIME_UP = "timeUp"
    AGENTS_FINISHED = "agentsFinished"
    COMMAND_FINISHED = "commandFinished"
    LOW_BATTERY = "lowBattery"
    OVERHEATING = "overheating"
    STOPPED_BY_USER = "stoppedByUser"
    STOPPED_EXTERNALLY = "stoppedExternally"

    @property
    def sentence(self) -> str:
        return {
            EndReason.TIME_UP: "Time's up. Sleep is back to normal.",
            EndReason.AGENTS_FINISHED: "Agents finished. Sleep is back to normal.",
            EndReason.COMMAND_FINISHED: "Command finished. Sleep is back to normal.",
            EndReason.LOW_BATTERY: "Stopped to protect the battery.",
            EndReason.OVERHEATING: "Stopped to let the laptop cool down.",
            EndReason.STOPPED_BY_USER: "Stopped.",
            EndReason.STOPPED_EXTERNALLY: "The lid lock ended outside Wick.",
        }[self]


def parse_iso(text: str | None) -> datetime | None:
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    # Comparing a naive datetime with an aware one raises, and the guard compares these on every tick.
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


@dataclass
class Conditions:
    now: datetime
    battery: Battery | None
    is_overheating: bool
    any_held_process_alive: bool


@dataclass
class Session:
    """A period during which the laptop stays awake. The file on disk is the single source of truth."""

    AGENT_GRACE: ClassVar[float] = 90.0

    startedAt: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    endsAt: str | None = None
    untilAgentsFinish: bool = False
    heldPIDs: list[int] = field(default_factory=list)
    endsWithHeldProcesses: bool = False
    batteryFloor: int | None = 20
    lastAgentSeen: str | None = None

    @classmethod
    def from_dict(cls, data: Any) -> Session:
        """Raises ValueError for anything but a well-formed session, because the guard acts on these fields."""
        if not isinstance(data, dict):
            raise ValueError("not an object")

        started = data.get("startedAt")
        ends = data.get("endsAt")
        seen = data.get("lastAgentSeen")
        held = data.get("heldPIDs", [])
        floor = data.get("batteryFloor", 20)
        if not (isinstance(started, str) and parse_iso(started)):
            raise ValueError("bad startedAt")
        for value in (ends, seen):
            if value is not None and not (isinstance(value, str) and parse_iso(value)):
                raise ValueError("bad timestamp")
        if not (isinstance(held, list) and all(type(pid) is int for pid in held)):
            raise ValueError("bad heldPIDs")
        if floor is not None and type(floor) is not int:
            raise ValueError("bad batteryFloor")

        return cls(
            startedAt=started,
            endsAt=ends,
            untilAgentsFinish=data.get("untilAgentsFinish") is True,
            heldPIDs=held,
            endsWithHeldProcesses=data.get("endsWithHeldProcesses") is True,
            batteryFloor=floor,
            lastAgentSeen=seen,
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def end_reason(self, conditions: Conditions) -> EndReason | None:
        """Safety outranks everything else the session asked for."""
        if conditions.is_overheating:
            return EndReason.OVERHEATING

        if self.batteryFloor is not None and conditions.battery is not None:
            if conditions.battery.is_discharging and conditions.battery.percent <= self.batteryFloor:
                return EndReason.LOW_BATTERY

        # A command that's still running outlives the timer: `wick on 10m; wick run build` shouldn't sleep mid-build.
        ends = parse_iso(self.endsAt)
        if ends and conditions.now >= ends and not conditions.any_held_process_alive:
            return EndReason.TIME_UP

        if self.endsWithHeldProcesses and not conditions.any_held_process_alive:
            return EndReason.COMMAND_FINISHED

        seen = parse_iso(self.lastAgentSeen)
        if self.untilAgentsFinish and seen and (conditions.now - seen).total_seconds() >= self.AGENT_GRACE:
            return EndReason.AGENTS_FINISHED

        return None


class SessionStore:
    def __init__(self, directory: Path | None = None) -> None:
        if directory is None:
            override = os.environ.get("WICK_STATE_DIR")
            state_home = os.environ.get("XDG_STATE_HOME")
            directory = Path(override) if override else (Path(state_home) if state_home else Path.home() / ".local" / "state") / "wick"
        self.directory = directory
        self.directory.mkdir(parents=True, exist_ok=True)

    @property
    def session_path(self) -> Path:
        return self.directory / "session.json"

    @property
    def last_end_path(self) -> Path:
        return self.directory / "last-end.json"

    @property
    def state_lock_path(self) -> Path:
        return self.directory / "state.lock"

    @property
    def guard_lock_path(self) -> Path:
        return self.directory / "guard.lock"

    @property
    def guard_pid_path(self) -> Path:
        return self.directory / "guard.pid"

    @property
    def guard_error_path(self) -> Path:
        return self.directory / "guard.error"

    def with_lock(self, body: Callable[[], Any]) -> Any:
        """Serialises every read-then-write of the session across the CLI, the tray and the guard.
        Not reentrant: never nest it. O_CLOEXEC, because a child inheriting the lock would hold it for life."""
        descriptor = os.open(str(self.state_lock_path), os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o644)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            return body()
        finally:
            os.close(descriptor)

    def load(self) -> Session | None:
        try:
            return Session.from_dict(json.loads(self.session_path.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            return None

    def has_unreadable_session(self) -> bool:
        """A file that's there but can't be trusted. Nothing can enforce it, so it has to be treated as an end."""
        return self.session_path.exists() and self.load() is None

    def _write(self, path: Path, text: str) -> None:
        temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
        temporary.write_text(text, encoding="utf-8")
        temporary.replace(path)

    def save(self, session: Session) -> None:
        self._write(self.session_path, json.dumps(session.to_dict(), indent=2))

    def discard_session(self) -> None:
        self.session_path.unlink(missing_ok=True)

    def finish(self, reason: EndReason) -> None:
        record = {"reason": reason.value, "at": datetime.now(timezone.utc).isoformat()}
        try:
            self._write(self.last_end_path, json.dumps(record, indent=2))
        except OSError:
            pass
        self.discard_session()

    def last_end(self) -> dict[str, str] | None:
        try:
            record = json.loads(self.last_end_path.read_text(encoding="utf-8"))
            return record if isinstance(record, dict) else None
        except (OSError, ValueError):
            return None

    def update(self, change: Callable[[Session], None]) -> Session | None:
        """Changes the session on disk if there still is one. Returns the result, or None if it has ended."""

        def apply() -> Session | None:
            session = self.load()
            if session is None:
                return None
            change(session)
            self.save(session)
            return session

        return self.with_lock(apply)

    def write_guard_pid(self) -> None:
        self._write(self.guard_pid_path, str(os.getpid()))

    def clear_guard_pid(self) -> None:
        # Only its own: the next guard may already have written one.
        if self.guard_pid() == os.getpid():
            self.guard_pid_path.unlink(missing_ok=True)

    def guard_pid(self) -> int | None:
        try:
            return int(self.guard_pid_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    def write_guard_error(self, message: str) -> None:
        self._write(self.guard_error_path, message)

    def clear_guard_error(self) -> None:
        self.guard_error_path.unlink(missing_ok=True)

    def guard_error(self) -> str | None:
        try:
            return self.guard_error_path.read_text(encoding="utf-8")
        except OSError:
            return None
