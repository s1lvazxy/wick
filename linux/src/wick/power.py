"""The one lock Wick exists for: a systemd-logind inhibitor on the lid switch.

The guard process is the only holder. It keeps the lock through systemd-inhibit, wrapped around a small loop that
ends when the guard does, so a guard killed with SIGKILL releases the lock within a second or two. Everything else
only ever asks logind whether the lock exists.

Going through systemd-inhibit rather than a D-Bus binding means one code path on every install. Inside a virtualenv
there is no dbus module, and a fallback that only runs there is the path nobody tests.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

WHO = "wick"
WHAT = "handle-lid-switch:sleep:idle"
WHY = "Keeping the laptop awake with the lid closed"

_ACQUIRE_TIMEOUT = 5.0


class PowerError(Exception):
    pass


class NotAuthorizedError(PowerError):
    pass


class CommandFailedError(PowerError):
    pass


class BelowBatteryFloorError(PowerError):
    pass


def simulated_file() -> Path | None:
    """Replaces the real lock with a file, so tests/e2e.sh can drive every path without logind."""
    path = os.environ.get("WICK_SIMULATE_POWER_FILE")
    return Path(path) if path else None


def set_simulated(disabled: bool) -> None:
    file = simulated_file()
    if file is None:
        return
    try:
        file.write_text("1\n" if disabled else "0\n", encoding="utf-8")
    except OSError as error:
        raise CommandFailedError(str(error)) from error


def _inhibitors() -> list[tuple[str, str, str, int, int]] | None:
    """(what, who, mode, uid, pid) for every inhibitor logind knows of, or None if logind can't be reached."""
    busctl = shutil.which("busctl")
    if busctl is None:
        return None
    try:
        result = subprocess.run(
            [
                busctl,
                "--json=short",
                "call",
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "ListInhibitors",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return None
        rows = json.loads(result.stdout)["data"][0]
        return [(row[0], row[1], row[3], row[4], row[5]) for row in rows]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError):
        return None


def lid_closed() -> bool | None:
    """Whether logind sees the lid as shut, or None if it can't be asked. It says no on a machine with no lid."""
    busctl = shutil.which("busctl")
    if busctl is None:
        return None
    try:
        result = subprocess.run(
            [
                busctl,
                "get-property",
                "org.freedesktop.login1",
                "/org/freedesktop/login1",
                "org.freedesktop.login1.Manager",
                "LidClosed",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    answer = result.stdout.split()
    if result.returncode != 0 or len(answer) != 2 or answer[0] != "b" or answer[1] not in ("true", "false"):
        return None
    return answer[1] == "true"


def logind_available() -> bool:
    return simulated_file() is not None or (shutil.which("systemd-inhibit") is not None and _inhibitors() is not None)


def lock_held() -> bool | None:
    """Whether this user's Wick lock is in place, according to logind and not to our own bookkeeping.

    None means logind couldn't be asked. That isn't the same as no: on a loaded machine one slow answer must not be
    mistaken for the lock having gone, and end a healthy session.
    """
    file = simulated_file()
    if file is not None:
        try:
            return file.read_text(encoding="utf-8").strip().startswith("1")
        except OSError:
            return False

    inhibitors = _inhibitors()
    if inhibitors is None:
        return None
    uid = os.getuid()
    return any(
        who == WHO and "handle-lid-switch" in what and mode == "block" and owner == uid
        for what, who, mode, owner, _ in inhibitors
    )


def sleep_disabled() -> bool:
    return lock_held() is True


def explain_refusal(detail: str) -> str:
    return (
        "logind refused the lid lock. It only allows this from an active local session, so it fails over SSH, "
        f"from cron or from a system service. Run `wick doctor` for the options. ({detail})"
    )


class Inhibitor:
    """Holds the lock for as long as it's acquired, and verifiably not a moment longer."""

    def __init__(self) -> None:
        self._process: subprocess.Popen | None = None

    def acquire(self) -> None:
        inhibit = shutil.which("systemd-inhibit")
        if inhibit is None:
            raise CommandFailedError("systemd-inhibit isn't installed. Wick on Linux needs systemd-logind.")

        # With no terminal attached it can't ask for a password, so logind's answer comes straight back. There's a
        # flag to say so, but it only exists from systemd 257. A process that lived on after the guard would hold
        # the lock with nobody enforcing the session, so it's tied to this one.
        tied_to_this_process = f"while kill -0 {os.getpid()} 2>/dev/null; do sleep 1; done"
        self._process = subprocess.Popen(
            [
                inhibit,
                f"--what={WHAT}",
                f"--who={WHO}",
                f"--why={WHY}",
                "--mode=block",
                "sh",
                "-c",
                tied_to_this_process,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )

        # systemd-inhibit starts fine and only then asks logind, so a refusal shows up as an early exit.
        deadline = time.monotonic() + _ACQUIRE_TIMEOUT
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                detail = (self._process.stderr.read() if self._process.stderr else "").strip()
                self._process = None
                if any(word in detail.lower() for word in ("denied", "authentication", "not authorized", "interactive")):
                    raise NotAuthorizedError(explain_refusal(detail))
                raise CommandFailedError(detail or "systemd-inhibit exited straight away.")
            if self._held():
                return
            time.sleep(0.05)

        self.release()
        raise CommandFailedError("logind didn't confirm the lock in time.")

    def _held(self) -> bool:
        if self._process is None:
            return False
        pid = self._process.pid
        return any(who == WHO and holder == pid for _, who, _, _, holder in _inhibitors() or [])

    def is_alive(self) -> bool:
        return self._process is not None and self._process.poll() is None

    def release(self) -> None:
        process = self._process
        if process is None:
            return
        self._process = None
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
            process.wait()
        if process.stderr:
            process.stderr.close()


def probe() -> str | None:
    """Tries the lock for real. Returns why it isn't possible, or None if it is."""
    if simulated_file() is not None or sleep_disabled():
        return None
    inhibitor = Inhibitor()
    try:
        inhibitor.acquire()
    except PowerError as error:
        return str(error)
    inhibitor.release()
    return None
