"""The `wick` command on Linux."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
from typing import NoReturn

from wick import agents, battery, core, desktop, durations, guard, power, thermal
from wick.session import EndReason, Session, SessionStore, parse_iso

USAGE = """wick keeps your laptop awake with the lid closed.

  wick on [2h]             stay awake, for a duration or until `wick off`
      --agents             also stop when running coding agents finish
      --floor <percent>    stop at this battery level on battery (default 20, or "off")
  wick set [2h|forever]    change the running session
      --agents on|off      stop or don't stop when agents finish
      --floor <percent>    change the battery level it stops at
  wick off                 back to normal sleep
  wick run <command...>    stay awake while a command runs, then go back to normal
  wick status [--json]     show the current state
  wick agents              list the coding agents Wick can see right now
  wick app                 run the top bar icon and panel
  wick setup               check permissions, and add the GNOME extension and the app launcher
  wick doctor              explain what Wick can and can't do on this machine
  wick uninstall           end any session and remove what `wick setup` added

Durations look like 90m, 2h or 1h30m.
"""


def fail(message: str, code: int = 1) -> NoReturn:
    sys.stderr.write(f"wick: {message}\n")
    sys.exit(code)


def executable_path() -> str:
    return str(Path(sys.argv[0]).resolve())


def print_status(executable: str, as_json: bool = False) -> None:
    store = SessionStore()
    core.Wick.reconcile(executable, store=store)
    held = power.lock_held()
    session = store.load()
    # If logind couldn't be asked just now, a session on disk is the best answer there is.
    awake = held is True or (held is None and session is not None)

    if as_json:
        current = battery.Battery.current()
        print(
            json.dumps(
                {
                    "sleepDisabled": awake,
                    "session": session.to_dict() if session else None,
                    "battery": {"percent": current.percent, "isDischarging": current.is_discharging} if current else None,
                    "agents": agents.running(),
                    # The panels poll this, so the lid is only asked about once there's heat for it to matter to.
                    "heat": thermal.Heat.current(always_ask_lid=False).to_dict(),
                    "lastEnd": store.last_end(),
                },
                indent=2,
                sort_keys=True,
            )
        )
        return

    if not awake:
        print("Sleeping normally.")
        return
    if session is None:
        print("Awake with the lid closed, but this session is ending.")
        return

    line = "Awake with the lid closed"
    ends = parse_iso(session.endsAt)
    if ends:
        line += f", {durations.clock((ends - datetime.now(timezone.utc)).total_seconds())} left"
    if session.untilAgentsFinish:
        line += ", or until agents finish"
    if session.heldPIDs:
        line += ", while a command runs"
    print(f"{line}.")
    print(thermal.Heat.current().sentence(is_guarded=True))


def start_or_fail(session: Session, executable: str, store: SessionStore | None = None) -> None:
    try:
        core.Wick.start(session, executable=executable, store=store)
    except power.PowerError as error:
        fail(str(error))


def take_floor(args: list[str], default: int | None = 20) -> int | None:
    """Removes `--floor <value>` from args, and returns the floor."""
    if "--floor" not in args:
        return default
    index = args.index("--floor")
    if index + 1 >= len(args):
        fail("--floor needs a value.")
    text = args[index + 1]
    del args[index : index + 2]
    if text == "off":
        return None
    if text.isdigit() and 1 <= int(text) <= 99:
        return int(text)
    fail('--floor takes a percentage from 1 to 99, or "off".')


def handle_on(args: list[str], executable: str) -> None:
    until_agents = "--agents" in args
    args = [argument for argument in args if argument != "--agents"]
    floor = take_floor(args)

    core.Wick.reconcile(executable)

    ends_at = None
    if args:
        seconds = durations.parse(args[0])
        if seconds is None or len(args) > 1:
            fail(f'"{" ".join(args)}" is not a duration. Try 90m or 2h.')
        ends_at = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()

    start_or_fail(Session(endsAt=ends_at, untilAgentsFinish=until_agents, batteryFloor=floor), executable)
    print_status(executable)
    if until_agents and ends_at is None and not agents.running():
        print("No agents running yet. Wick waits for one to start, then stops when the last one exits.")


def handle_set(args: list[str]) -> None:
    """Changes a running session in place. It refuses if the session has ended, so it can't revive one."""
    changes = []

    if "--agents" in args:
        index = args.index("--agents")
        value = args[index + 1] if index + 1 < len(args) else None
        if value not in ("on", "off"):
            fail('--agents takes "on" or "off".')
        del args[index : index + 2]
        changes.append(lambda session: setattr(session, "untilAgentsFinish", value == "on"))

    if "--floor" in args:
        floor = take_floor(args)
        changes.append(lambda session: setattr(session, "batteryFloor", floor))

    if args:
        if len(args) > 1:
            fail(f'"{" ".join(args)}" is not a duration. Try 90m, 2h or forever.')
        if args[0] == "forever":
            ends_at = None
        else:
            seconds = durations.parse(args[0])
            if seconds is None:
                fail(f'"{args[0]}" is not a duration. Try 90m, 2h or forever.')
            ends_at = (datetime.now(timezone.utc) + timedelta(seconds=seconds)).isoformat()
        changes.append(lambda session: setattr(session, "endsAt", ends_at))

    if not changes:
        fail("wick set needs something to change, like: wick set 2h")

    def apply(session: Session) -> None:
        for change in changes:
            change(session)

    if SessionStore().update(apply) is None:
        fail("no session is running.")
    print_status(executable_path())


def handle_off(args: list[str]) -> None:
    store = SessionStore()
    if "--session-only" in args and store.load() is None:
        return
    try:
        core.Wick.stop(EndReason.STOPPED_BY_USER, store=store)
    except power.PowerError as error:
        fail(f"could not stop: {error}")
    print("Sleeping normally.")


def handle_run(args: list[str], executable: str) -> NoReturn:
    # Options come before the command, so that the command's own --floor stays its own.
    leading = []
    while args[:1] == ["--floor"]:
        leading, args = leading + args[:2], args[2:]
    floor = take_floor(leading)

    command = args[1:] if args[:1] == ["--"] else args
    if not command:
        fail("wick run needs a command, like: wick run claude")

    store = SessionStore()
    core.Wick.reconcile(executable, store=store)
    pid = os.getpid()

    if store.update(lambda session: session.heldPIDs.append(pid)) is None:
        start_or_fail(Session(heldPIDs=[pid], endsWithHeldProcesses=True, batteryFloor=floor), executable, store)

    problem = None
    code = 0
    try:
        # Same process group as the shell, so an interactive command keeps the terminal and receives Ctrl-C.
        process = subprocess.Popen(command)
        # Ignored only now, because a child inherits ignored signals. Wick stays alive to put sleep back.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGQUIT, signal.SIG_IGN)
        code = process.wait()
        code = 128 - code if code < 0 else code
    except FileNotFoundError:
        problem, code = f"{command[0]}: command not found", 127
    except OSError as error:
        problem, code = f"could not run {command[0]}: {error.strerror}", 126

    try:
        core.Wick.release_hold(pid, store)
    except power.PowerError:
        pass  # The guard sees the held process has gone, and ends the session itself.

    if problem:
        fail(problem, code)
    sys.exit(code)


def handle_doctor() -> int:
    print(f"Kernel        {os.uname().release}")

    available = power.logind_available()
    print(f"logind        {'reachable' if available else 'NOT REACHABLE'}")
    if not available:
        print("\nWick on Linux needs systemd-logind, with busctl and systemd-inhibit. This system doesn't have them.")
        return 1

    refusal = power.probe()
    print(f"Lid lock      {'allowed' if refusal is None else 'REFUSED'}")
    print(f"Currently     {'held by Wick' if power.sleep_disabled() else 'not held'}")

    current = battery.Battery.current()
    if current:
        state = "discharging" if current.is_discharging else "charging or full"
        print(f"Battery       {current.percent}%, {state}")
    else:
        print("Battery       none found, so the battery floor doesn't apply")

    heat = thermal.Heat.current()
    hottest = heat.hottest
    if hottest:
        critical = f", critical at {hottest.critical:.0f}°C" if hottest.critical else ""
        print(f"Hottest zone  {hottest.temperature:.0f}°C ({hottest.name}{critical})")
    if heat.battery_temperature is not None:
        print(f"Battery heat  {heat.battery_temperature:.0f}°C, and {thermal.HOT_BATTERY_C:.0f}°C counts as hot")
    if hottest is None and heat.battery_temperature is None:
        print("Thermal       no sensors found, so heat protection can't work here")
    if heat.lid_closed is not None:
        print(f"Lid           {'closed' if heat.lid_closed else 'open'}")
    else:
        print("Lid           no switch found, so heat is only acted on when it's critical")

    running = agents.running()
    print(f"Agents        {', '.join(running) if running else 'none running'}")

    if refusal is not None:
        print(f"\n{refusal}\n\nTo allow it without an active local session, as root:\n\n{desktop.polkit_rule_command()}")
        return 1
    return 0


def handle_setup() -> int:
    refusal = power.probe()
    if refusal is not None:
        print(f"{refusal}\n\nTo allow it without an active local session, as root:\n\n{desktop.polkit_rule_command()}\n")
    else:
        print("Lid lock: allowed, and no password or root needed.")

    print(desktop.install_launcher(executable_path()))
    print(desktop.install_gnome_extension())
    return 0 if refusal is None else 1


def run_app(executable: str) -> None:
    """The tray needs PyGObject, which is a system package and isn't visible from inside a pipx virtualenv."""
    try:
        import gi  # noqa: F401
    except ImportError:
        # A virtualenv's python is a symlink to the system's, so comparing paths can't tell them apart.
        system_python = shutil.which("python3", path="/usr/bin")
        if system_python and not os.environ.get("WICK_REEXEC"):
            package_parent = str(Path(__file__).resolve().parent.parent)
            environment = dict(os.environ, PYTHONPATH=package_parent, WICK_REEXEC="1", WICK_EXECUTABLE=executable)
            os.execve(system_python, [system_python, "-c", "from wick.cli import main; main()", "app"], environment)
        fail(desktop.tray_dependencies_hint())

    try:
        from wick import tray
    except (ImportError, ValueError) as error:  # PyGObject is there, but GTK's own bindings aren't.
        fail(f"{error}\n\n{desktop.tray_dependencies_hint()}")

    try:
        tray.launch_app(os.environ.get("WICK_EXECUTABLE", executable))
    except tray.TrayUnavailable as error:
        fail(f"{error}\n\n{desktop.tray_dependencies_hint()}")


def main() -> None:
    args = sys.argv[1:]
    command = args.pop(0) if args else "status"
    executable = executable_path()

    if command == "on":
        handle_on(args, executable)
    elif command == "set":
        handle_set(args)
    elif command == "off":
        handle_off(args)
    elif command == "run":
        handle_run(args, executable)
    elif command == "status":
        print_status(executable, as_json="--json" in args)
    elif command == "agents":
        print("\n".join(agents.running()) or "No agents running.")
    elif command == "guard":
        guard.run_guard()
    elif command == "app":
        run_app(executable)
    elif command == "doctor":
        sys.exit(handle_doctor())
    elif command == "setup":
        sys.exit(handle_setup())
    elif command == "uninstall":
        handle_off(["--session-only"])
        print(desktop.uninstall())
    elif command in ("help", "--help", "-h"):
        print(USAGE)
    elif command in ("version", "--version"):
        print(f"wick {durations.VERSION}")
    else:
        fail(f'unknown command "{command}".\n\n{USAGE}')


if __name__ == "__main__":
    main()
