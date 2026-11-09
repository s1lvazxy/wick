"""Unit tests for the logic that decides when a session ends and what the machine's state is. Standard library only."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from wick import agents, battery, durations, power, thermal  # noqa: E402
from wick.battery import Battery  # noqa: E402
from wick.session import Conditions, EndReason, Session, SessionStore, parse_iso  # noqa: E402

NOW = datetime(2026, 11, 2, 12, 0, tzinfo=timezone.utc)


def conditions(battery_state=Battery(80, False), hot=False, held=False):
    return Conditions(now=NOW, battery=battery_state, is_overheating=hot, any_held_process_alive=held)


class EndRules(unittest.TestCase):
    def test_an_open_session_keeps_running(self):
        self.assertIsNone(Session().end_reason(conditions()))

    def test_ends_at_the_deadline_and_not_before(self):
        self.assertEqual(Session(endsAt=NOW.isoformat()).end_reason(conditions()), EndReason.TIME_UP)
        later = (NOW + timedelta(seconds=1)).isoformat()
        self.assertIsNone(Session(endsAt=later).end_reason(conditions()))

    def test_battery_floor_only_applies_while_discharging(self):
        session = Session(batteryFloor=20)
        self.assertEqual(session.end_reason(conditions(Battery(20, True))), EndReason.LOW_BATTERY)
        self.assertIsNone(session.end_reason(conditions(Battery(21, True))))
        self.assertIsNone(session.end_reason(conditions(Battery(5, False))))

    def test_no_floor_means_the_battery_is_ignored(self):
        self.assertIsNone(Session(batteryFloor=None).end_reason(conditions(Battery(1, True))))

    def test_desktops_have_no_battery_to_protect(self):
        self.assertIsNone(Session().end_reason(conditions(None)))

    def test_heat_outranks_everything(self):
        session = Session(endsAt=NOW.isoformat(), batteryFloor=100)
        self.assertEqual(session.end_reason(conditions(Battery(1, True), hot=True)), EndReason.OVERHEATING)

    def test_ends_with_its_held_command_when_it_exists_for_one(self):
        session = Session(heldPIDs=[42], endsWithHeldProcesses=True)
        self.assertIsNone(session.end_reason(conditions(held=True)))
        self.assertEqual(session.end_reason(conditions(held=False)), EndReason.COMMAND_FINISHED)

    def test_an_open_session_survives_a_command_that_joined_it(self):
        self.assertIsNone(Session(heldPIDs=[]).end_reason(conditions()))

    def test_a_running_command_outlives_the_timer(self):
        session = Session(endsAt=NOW.isoformat(), heldPIDs=[42])
        self.assertIsNone(session.end_reason(conditions(held=True)))
        self.assertEqual(session.end_reason(conditions(held=False)), EndReason.TIME_UP)

    def test_safety_outranks_a_running_command(self):
        session = Session(heldPIDs=[42], batteryFloor=20)
        self.assertEqual(session.end_reason(conditions(Battery(10, True), held=True)), EndReason.LOW_BATTERY)
        self.assertEqual(session.end_reason(conditions(hot=True, held=True)), EndReason.OVERHEATING)

    def test_waits_for_an_agent_to_appear_before_releasing(self):
        self.assertIsNone(Session(untilAgentsFinish=True).end_reason(conditions()))

    def test_gives_agents_a_grace_period_to_restart(self):
        just_gone = (NOW - timedelta(seconds=Session.AGENT_GRACE - 1)).isoformat()
        long_gone = (NOW - timedelta(seconds=Session.AGENT_GRACE)).isoformat()
        self.assertIsNone(Session(untilAgentsFinish=True, lastAgentSeen=just_gone).end_reason(conditions()))
        self.assertEqual(
            Session(untilAgentsFinish=True, lastAgentSeen=long_gone).end_reason(conditions()), EndReason.AGENTS_FINISHED
        )

    def test_a_naive_timestamp_cant_crash_the_guard(self):
        self.assertEqual(Session(endsAt="2020-01-01T00:00:00").end_reason(conditions()), EndReason.TIME_UP)
        self.assertEqual(parse_iso("2026-01-01T00:00:00Z"), datetime(2026, 1, 1, tzinfo=timezone.utc))
        self.assertIsNone(parse_iso("nope"))


class SessionFile(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = SessionStore(Path(self.directory.name))

    def test_round_trips(self):
        session = Session(endsAt=NOW.isoformat(), untilAgentsFinish=True, heldPIDs=[7], batteryFloor=30)
        self.store.save(session)
        self.assertEqual(self.store.load(), session)

    def test_finishing_clears_the_session_and_records_why(self):
        self.store.save(Session())
        self.store.finish(EndReason.LOW_BATTERY)
        self.assertIsNone(self.store.load())
        self.assertEqual(self.store.last_end()["reason"], "lowBattery")

    def test_no_file_is_not_an_unreadable_file(self):
        self.assertFalse(self.store.has_unreadable_session())

    def test_anything_malformed_is_flagged_rather_than_trusted(self):
        started = '"startedAt": "2026-01-01T00:00:00Z"'
        for junk in [
            "nope",
            "",
            "[]",
            "null",
            "1",
            '"text"',
            "{}",
            '{"startedAt": "nope"}',
            '{"startedAt": 5}',
            "{" + started + ', "heldPIDs": "oops"}',
            "{" + started + ', "heldPIDs": ["1"]}',
            "{" + started + ', "heldPIDs": [true]}',
            "{" + started + ', "endsAt": 12}',
            "{" + started + ', "endsAt": "soon"}',
            "{" + started + ', "lastAgentSeen": []}',
            "{" + started + ', "batteryFloor": "low"}',
            "{" + started + ', "batteryFloor": true}',
        ]:
            with self.subTest(junk=junk):
                self.store.session_path.write_text(junk, encoding="utf-8")
                self.assertIsNone(self.store.load())
                self.assertTrue(self.store.has_unreadable_session())

    def test_update_changes_a_live_session_and_refuses_to_revive_an_ended_one(self):
        self.assertIsNone(self.store.update(lambda session: session.heldPIDs.append(1)))
        self.assertIsNone(self.store.load())
        self.store.save(Session())
        self.assertEqual(self.store.update(lambda session: session.heldPIDs.append(1)).heldPIDs, [1])
        self.assertEqual(self.store.load().heldPIDs, [1])

    def test_agent_grace_isnt_saved(self):
        self.store.save(Session())
        self.assertNotIn("AGENT_GRACE", json.loads(self.store.session_path.read_text(encoding="utf-8")))

    def test_a_garbage_guard_pid_reads_as_none(self):
        self.store.guard_pid_path.write_text("x", encoding="utf-8")
        self.assertIsNone(self.store.guard_pid())


class Durations(unittest.TestCase):
    def test_parses(self):
        for text, seconds in [("90", 5400), ("90m", 5400), ("2h", 7200), ("1h30m", 5400), ("45s", 45), ("2H", 7200), (" 5m ", 300), ("1.5", 90)]:
            with self.subTest(text=text):
                self.assertEqual(durations.parse(text), seconds)

    def test_rejects(self):
        for text in ["", "soon", "0", "-5", "2x", "h", "1h soon", "inf", "-inf", "nan", "1e18", "9999999999h", "0m", "0h0m"]:
            with self.subTest(text=text):
                self.assertIsNone(durations.parse(text))

    def test_clock(self):
        self.assertEqual(durations.clock(6129), "1:42:09")
        self.assertEqual(durations.clock(59.2), "1:00")
        self.assertEqual(durations.clock(-3), "0:00")

    def test_compact(self):
        self.assertEqual(durations.compact(7500), "2h 05m")
        self.assertEqual(durations.compact(2520), "42m")
        self.assertEqual(durations.compact(30), "<1m")
        self.assertEqual(durations.compact(3599), "1h 00m")


class AgentMatching(unittest.TestCase):
    def test_finds_agents(self):
        for process, arguments, expected in [
            ("claude", [], "Claude Code"),
            ("codex", [], "Codex"),
            ("node", ["node", "/usr/bin/codex"], "Codex"),
            ("node", ["node", "/usr/local/lib/claude.js"], "Claude Code"),
            ("python3", ["python3", "/home/me/.local/bin/aider"], "Aider"),
            ("2.1.312", ["claude"], "Claude Code"),
            ("2.1.312", ["/home/me/.local/bin/claude", "--resume"], "Claude Code"),
            ("hermes", [], "Hermes Agent"),
        ]:
            with self.subTest(process=process, arguments=arguments):
                self.assertEqual(agents.match_command(process, arguments), expected)

    def test_ignores_everything_else(self):
        for process, arguments in [
            ("Claude", []),
            ("node", ["node", "server.js"]),
            ("node", []),
            ("zsh", []),
            ("zsh", ["zsh", "claude"]),
            ("vim", ["vim", "codex"]),
            ("wick", ["python3", "/usr/bin/wick", "run", "claude"]),
        ]:
            with self.subTest(process=process, arguments=arguments):
                self.assertIsNone(agents.match_command(process, arguments))


class FakeSysfs(unittest.TestCase):
    """Builds a /sys tree, because real hardware is the part these rules exist to survive."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        environment = {"WICK_SYSFS_ROOT": str(self.root)}
        patcher = mock.patch.dict(os.environ, environment)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in ("WICK_SIMULATE_BATTERY", "WICK_SIMULATE_POWER_FILE", "WICK_SIMULATE_THERMAL", "WICK_SIMULATE_LID"):
            os.environ.pop(name, None)

    def files(self, base, **values):
        path = self.root / base
        path.mkdir(parents=True, exist_ok=True)
        for name, value in values.items():
            (path / name).write_text(f"{value}\n", encoding="utf-8")

    def supply(self, name, **values):
        self.files(f"class/power_supply/{name}", **values)

    def zone(self, number, temp, **values):
        self.files(f"class/thermal/thermal_zone{number}", temp=int(temp * 1000), **values)


class Batteries(FakeSysfs):
    def test_no_power_supplies_means_no_battery(self):
        self.assertIsNone(Battery.current())

    def test_reads_one_battery(self):
        self.supply("BAT0", type="Battery", capacity=62, status="Discharging")
        self.assertEqual(Battery.current(), Battery(62, True))

    def test_mains_alone_is_not_a_battery(self):
        self.supply("AC", type="Mains", online=1)
        self.assertIsNone(Battery.current())

    def test_a_wireless_mouse_is_not_the_laptop(self):
        self.supply("hidpp_battery_0", type="Battery", scope="Device", capacity=3, status="Discharging")
        self.assertIsNone(Battery.current())

    def test_unusual_battery_names_still_count(self):
        self.supply("macsmc-battery", type="Battery", capacity=70, status="Charging")
        self.assertEqual(Battery.current(), Battery(70, False))

    def test_two_batteries_count_as_their_total_energy(self):
        # One nearly flat and one nearly full, as ThinkPads drain them, is plenty left: not 5%.
        self.supply("BAT0", type="Battery", capacity=5, energy_now=1000, energy_full=20000, status="Discharging")
        self.supply("BAT1", type="Battery", capacity=95, energy_now=57000, energy_full=60000, status="Not charging")
        self.assertEqual(Battery.current(), Battery(72, True))

    def test_falls_back_to_charge_then_to_capacity(self):
        self.supply("BAT0", type="Battery", charge_now=1000, charge_full=4000, status="Charging")
        self.assertEqual(Battery.current().percent, 25)

    def test_full_or_idle_isnt_discharging(self):
        for status in ("Full", "Not charging", "Charging", "Unknown"):
            with self.subTest(status=status):
                self.supply("BAT0", type="Battery", capacity=100, status=status)
                self.assertFalse(Battery.current().is_discharging)

    def test_junk_values_dont_crash_or_count(self):
        self.supply("BAT0", type="Battery", capacity="nonsense", status="Discharging")
        self.assertIsNone(Battery.current())

    def test_a_zero_full_charge_cant_divide_by_zero(self):
        self.supply("BAT0", type="Battery", capacity=50, energy_now=0, energy_full=0, status="Discharging")
        self.assertEqual(Battery.current(), Battery(50, True))

    def test_percent_stays_in_range(self):
        self.supply("BAT0", type="Battery", energy_now=23000, energy_full=20000, status="Charging")
        self.assertEqual(Battery.current().percent, 100)


class WatchedHeat(FakeSysfs):
    lid = None

    def monitor(self):
        self.now = 0.0
        return thermal.Monitor(clock=lambda: self.now, lid=lambda: self.lid)

    def stays_hot_for(self, seconds):
        monitor = self.monitor()
        monitor.is_overheating()
        self.now = seconds
        return monitor.is_overheating()


class Heat(WatchedHeat):
    """The first rung: critical, whatever the lid is doing. These all run with it open."""

    lid = False

    def test_no_sensors_is_not_overheating(self):
        self.assertFalse(thermal.Monitor().is_overheating())

    def test_a_cpu_boosting_at_95_is_normal(self):
        self.zone(0, 97, type="x86_pkg_temp", trip_point_0_type="critical", trip_point_0_temp=110000)
        self.assertFalse(self.stays_hot_for(3600))

    def test_a_hot_trip_point_is_not_critical(self):
        self.zone(0, 85, trip_point_0_type="hot", trip_point_0_temp=80000)
        self.assertFalse(self.stays_hot_for(3600))

    def test_close_to_critical_counts_once_its_lasted(self):
        self.zone(0, 106, trip_point_0_type="critical", trip_point_0_temp=108000)
        self.assertFalse(self.stays_hot_for(29))
        self.assertTrue(self.stays_hot_for(30))

    def test_being_asked_often_doesnt_make_it_trigger_sooner(self):
        self.zone(0, 107, trip_point_0_type="critical", trip_point_0_temp=108000)
        monitor = self.monitor()
        for _ in range(100):
            self.now += 0.1
            self.assertFalse(monitor.is_overheating())

    def test_a_spike_that_passes_starts_the_count_again(self):
        self.zone(0, 107, trip_point_0_type="critical", trip_point_0_temp=108000)
        monitor = self.monitor()
        monitor.is_overheating()
        self.now = 25
        self.zone(0, 60)
        self.assertFalse(monitor.is_overheating())
        self.zone(0, 107)
        self.now = 30
        self.assertFalse(monitor.is_overheating())
        self.now = 60
        self.assertTrue(monitor.is_overheating())

    def test_without_a_limit_only_extreme_heat_counts(self):
        self.zone(0, 100)
        self.assertFalse(self.stays_hot_for(3600))
        self.zone(0, 106)
        self.assertTrue(self.stays_hot_for(30))

    def test_sensors_reading_nonsense_are_ignored(self):
        for number, value in enumerate([0, -273, 255, 149.5 + 1000]):
            self.zone(number, value)
        (self.root / "class/thermal/thermal_zone9").mkdir(parents=True)
        (self.root / "class/thermal/thermal_zone9/temp").write_text("not a number", encoding="utf-8")
        self.assertFalse(self.stays_hot_for(3600))

    def test_an_implausible_critical_trip_point_falls_back_to_the_ceiling(self):
        self.zone(0, 90, trip_point_0_type="critical", trip_point_0_temp=255000)
        self.assertFalse(self.stays_hot_for(3600))

    def test_the_cpus_own_sensors_count_at_their_limit(self):
        self.files("class/hwmon/hwmon0", name="coretemp", temp1_input=99500, temp1_crit=100000)
        self.assertTrue(self.stays_hot_for(30))
        self.assertEqual(thermal.zones()[0].name, "coretemp")

    def test_a_cpu_a_little_under_its_limit_is_normal(self):
        self.files("class/hwmon/hwmon0", name="coretemp", temp1_input=96000, temp1_crit=100000)
        self.assertFalse(self.stays_hot_for(3600))

    def test_simulation_overrides(self):
        with mock.patch.dict(os.environ, {"WICK_SIMULATE_THERMAL": "critical"}):
            self.assertTrue(thermal.Monitor().is_overheating())


class HeatWithTheLidClosed(WatchedHeat):
    """The second rung: heat that would be fine on a desk, with nowhere to go."""

    lid = True

    def battery(self, celsius, name="BAT0", **values):
        self.supply(name, type="Battery", capacity=80, status="Discharging", temp=int(celsius * 10), **values)

    def test_a_hot_battery_counts_once_its_lasted_a_minute(self):
        self.battery(45)
        self.assertFalse(self.stays_hot_for(59))
        self.assertTrue(self.stays_hot_for(60))

    def test_a_battery_just_under_the_line_is_fine(self):
        self.battery(44.9)
        self.assertFalse(self.stays_hot_for(3600))

    def test_with_the_lid_open_a_hot_battery_never_stops_it(self):
        self.battery(55)
        self.lid = False
        self.assertFalse(self.stays_hot_for(3600))

    def test_not_knowing_about_the_lid_counts_as_open(self):
        self.battery(55)
        self.lid = None
        self.assertFalse(self.stays_hot_for(3600))

    def test_a_zone_nearing_its_critical_point_counts(self):
        self.zone(0, 100, trip_point_0_type="critical", trip_point_0_temp=108000)
        self.assertFalse(self.stays_hot_for(59))
        self.assertTrue(self.stays_hot_for(60))

    def test_a_zone_further_away_is_fine(self):
        self.zone(0, 99, trip_point_0_type="critical", trip_point_0_temp=108000)
        self.assertFalse(self.stays_hot_for(3600))

    def test_the_cpus_own_sensors_count_from_five_degrees_away(self):
        self.files("class/hwmon/hwmon0", name="coretemp", temp1_input=95000, temp1_crit=100000)
        self.assertFalse(self.stays_hot_for(59))
        self.assertTrue(self.stays_hot_for(60))
        self.files("class/hwmon/hwmon0", name="coretemp", temp1_input=94000, temp1_crit=100000)
        self.assertFalse(self.stays_hot_for(3600))

    def test_a_sensor_with_no_limit_still_needs_to_be_extreme(self):
        self.zone(0, 100)
        self.assertFalse(self.stays_hot_for(3600))

    def test_critical_doesnt_wait_the_full_minute(self):
        self.zone(0, 106, trip_point_0_type="critical", trip_point_0_temp=108000)
        self.assertFalse(self.stays_hot_for(29))
        self.assertTrue(self.stays_hot_for(30))

    def test_a_cool_sample_starts_the_minute_again(self):
        self.battery(46)
        monitor = self.monitor()
        monitor.is_overheating()
        self.now = 55
        self.battery(39)
        self.assertFalse(monitor.is_overheating())
        self.battery(46)
        self.now = 60
        self.assertFalse(monitor.is_overheating())
        self.now = 119
        self.assertFalse(monitor.is_overheating())
        self.now = 120
        self.assertTrue(monitor.is_overheating())

    def test_opening_the_lid_starts_the_minute_again(self):
        self.battery(46)
        monitor = self.monitor()
        monitor.is_overheating()
        self.now, self.lid = 55, False
        self.assertFalse(monitor.is_overheating())
        self.now, self.lid = 60, True
        self.assertFalse(monitor.is_overheating())
        self.now = 120
        self.assertTrue(monitor.is_overheating())

    def test_being_asked_often_doesnt_make_it_trigger_sooner(self):
        self.battery(50)
        monitor = self.monitor()
        for _ in range(590):
            self.now += 0.1
            self.assertFalse(monitor.is_overheating())

    def test_the_lid_is_only_asked_about_once_theres_heat(self):
        self.battery(30)
        self.zone(0, 50, trip_point_0_type="critical", trip_point_0_temp=108000)
        asked = []
        monitor = thermal.Monitor(clock=lambda: 0.0, lid=lambda: asked.append(1) or True)
        monitor.is_overheating()
        self.assertEqual(asked, [])
        self.battery(46)
        monitor.is_overheating()
        self.assertEqual(asked, [1])

    def test_battery_readings_that_cant_be_real_are_ignored(self):
        for celsius in (0, -273.2, 0.5, 100.5, 6553.5):
            with self.subTest(celsius=celsius):
                self.battery(celsius)
                self.assertIsNone(battery.temperature())
                self.assertFalse(self.stays_hot_for(3600))
        self.supply("BAT0", type="Battery", temp="warm")
        self.assertIsNone(battery.temperature())

    def test_a_laptop_with_no_battery_sensor_just_has_no_reading(self):
        self.supply("BAT0", type="Battery", capacity=80, status="Discharging")
        self.assertIsNone(battery.temperature())
        self.assertFalse(self.stays_hot_for(3600))

    def test_a_wireless_mouse_isnt_the_laptop(self):
        self.supply("hidpp_battery_0", type="Battery", scope="Device", temp=600)
        self.assertIsNone(battery.temperature())

    def test_the_warmest_of_two_batteries_counts(self):
        self.battery(33, "BAT0")
        self.battery(46.5, "BAT1")
        self.assertEqual(battery.temperature(), 46.5)
        self.assertTrue(self.stays_hot_for(60))

    def test_a_simulated_lock_never_reads_the_real_battery(self):
        self.battery(60)
        with mock.patch.dict(os.environ, {"WICK_SIMULATE_POWER_FILE": "/nowhere"}):
            self.assertEqual(battery.temperature(), 60)
            del os.environ["WICK_SYSFS_ROOT"]
            self.assertIsNone(battery.temperature())


class Lid(FakeSysfs):
    def setUp(self):
        super().setUp()
        self.acpi = self.root / "acpi-lids"
        patcher = mock.patch.object(thermal, "_ACPI_LIDS", self.acpi)
        patcher.start()
        self.addCleanup(patcher.stop)

    def acpi_says(self, state):
        (self.acpi / "LID0").mkdir(parents=True, exist_ok=True)
        (self.acpi / "LID0" / "state").write_text(f"state:      {state}\n", encoding="utf-8")

    def logind_says(self, output, returncode=0):
        result = mock.Mock(returncode=returncode, stdout=output)
        return mock.patch.multiple(
            "wick.power",
            shutil=mock.Mock(which=mock.Mock(return_value="/usr/bin/busctl")),
            subprocess=mock.Mock(run=mock.Mock(return_value=result), SubprocessError=subprocess.SubprocessError),
        )

    def test_logind_saying_closed_is_enough(self):
        with self.logind_says("b true\n"):
            self.assertIs(thermal.lid_closed(), True)

    def test_logind_says_open_for_a_desktop_too_so_that_alone_is_unknown(self):
        with self.logind_says("b false\n"):
            self.assertIsNone(thermal.lid_closed())

    def test_open_is_believed_where_acpi_knows_of_a_lid(self):
        self.acpi_says("open")
        with self.logind_says("b false\n"):
            self.assertIs(thermal.lid_closed(), False)

    def test_acpi_fills_in_when_logind_cant_be_asked(self):
        self.acpi_says("closed")
        for output, returncode in (("", 1), ("s \"maybe\"\n", 0), ("garbage", 0), ("b perhaps", 0)):
            with self.subTest(output=output), self.logind_says(output, returncode):
                self.assertIsNone(power.lid_closed())
                self.assertIs(thermal.lid_closed(), True)

    def test_no_busctl_and_no_acpi_is_unknown(self):
        with mock.patch("shutil.which", return_value=None):
            self.assertIsNone(power.lid_closed())
            self.assertIsNone(thermal.lid_closed())

    def test_a_slow_logind_reads_as_unknown_rather_than_crashing(self):
        slow = subprocess.TimeoutExpired("busctl", 5)
        with mock.patch("shutil.which", return_value="/usr/bin/busctl"), mock.patch("subprocess.run", side_effect=slow):
            self.assertIsNone(power.lid_closed())

    def test_simulation_overrides(self):
        for value, expected in (("closed", True), ("open", False), ("CLOSED", True)):
            with self.subTest(value=value), mock.patch.dict(os.environ, {"WICK_SIMULATE_LID": value}):
                self.assertIs(thermal.lid_closed(), expected)

    def test_a_simulated_lock_never_asks_about_the_real_lid(self):
        self.acpi_says("closed")
        with mock.patch.dict(os.environ, {"WICK_SIMULATE_POWER_FILE": "/nowhere"}), self.logind_says("b true\n"):
            self.assertIsNone(thermal.lid_closed())


class HeatInWords(FakeSysfs):
    def heat(self, lid=None):
        return thermal.Heat.current(lid=lambda: lid)

    def test_cool_warm_and_hot(self):
        self.assertEqual(self.heat().word, "Cool")
        self.supply("BAT0", type="Battery", temp=400)
        self.assertEqual(self.heat().word, "Warm")
        self.supply("BAT0", type="Battery", temp=450)
        self.assertEqual(self.heat().word, "Hot")

    def test_a_cpu_working_hard_reads_as_warm_then_hot(self):
        self.files("class/hwmon/hwmon0", name="coretemp", temp1_input=60000, temp1_crit=100000)
        self.assertEqual(self.heat().word, "Cool")
        self.files("class/hwmon/hwmon0", name="coretemp", temp1_input=90000, temp1_crit=100000)
        self.assertEqual(self.heat().word, "Warm")
        self.files("class/hwmon/hwmon0", name="coretemp", temp1_input=96000, temp1_crit=100000)
        self.assertEqual(self.heat().word, "Hot")

    def test_says_what_it_knows_and_nothing_it_doesnt(self):
        self.assertEqual(self.heat().sentence(is_guarded=True), "Heat: cool.")
        self.supply("BAT0", type="Battery", temp=312)
        self.assertEqual(self.heat(lid=False).sentence(is_guarded=True), "Heat: cool, battery 31°C, lid open.")

    def test_only_promises_to_stop_when_a_guard_is_watching(self):
        self.supply("BAT0", type="Battery", temp=460)
        closed = self.heat(lid=True)
        self.assertEqual(closed.sentence(is_guarded=False), "Heat: hot, battery 46°C, lid closed.")
        self.assertEqual(
            closed.sentence(is_guarded=True), "Heat: hot, battery 46°C, lid closed. Wick stops if this lasts a minute."
        )
        self.assertEqual(self.heat(lid=False).sentence(is_guarded=True), "Heat: hot, battery 46°C, lid open.")

    def test_what_the_panels_get(self):
        self.supply("BAT0", type="Battery", temp=312)
        self.assertEqual(
            thermal.Heat.current(lid=lambda: True, always_ask_lid=False).to_dict(),
            {"word": "Cool", "batteryCelsius": 31.2, "lidClosed": None},
        )
        self.supply("BAT0", type="Battery", temp=460)
        self.assertEqual(
            thermal.Heat.current(lid=lambda: True, always_ask_lid=False).to_dict(),
            {"word": "Hot", "batteryCelsius": 46.0, "lidClosed": True},
        )


class NoLogind(unittest.TestCase):
    """What happens on a system without systemd, like Alpine or Void."""

    def setUp(self):
        for name in ("WICK_SIMULATE_POWER_FILE",):
            patcher = mock.patch.dict(os.environ)
            patcher.start()
            self.addCleanup(patcher.stop)
            os.environ.pop(name, None)

    def test_reports_unavailable_and_not_awake(self):
        with mock.patch("shutil.which", return_value=None):
            self.assertFalse(power.logind_available())
            self.assertFalse(power.sleep_disabled())

    def test_acquiring_explains_itself(self):
        with mock.patch("shutil.which", return_value=None):
            with self.assertRaises(power.CommandFailedError) as caught:
                power.Inhibitor().acquire()
        self.assertIn("systemd-inhibit", str(caught.exception))

    def test_probe_returns_the_reason(self):
        with mock.patch("shutil.which", return_value=None):
            self.assertIn("systemd-inhibit", power.probe())

    def test_not_being_able_to_ask_is_not_the_same_as_no(self):
        with mock.patch("shutil.which", return_value=None):
            self.assertIsNone(power.lock_held())
        failed = mock.Mock(returncode=1, stdout="")
        with mock.patch("shutil.which", return_value="/usr/bin/busctl"), mock.patch("subprocess.run", return_value=failed):
            self.assertIsNone(power.lock_held())
        slow = subprocess.TimeoutExpired("busctl", 5)
        with mock.patch("shutil.which", return_value="/usr/bin/busctl"), mock.patch("subprocess.run", side_effect=slow):
            self.assertIsNone(power.lock_held())

    def test_garbage_from_busctl_reads_as_unavailable(self):
        for output in ("not json", "{}", '{"data":[]}', '{"data":[[["too","short"]]]}'):
            with self.subTest(output=output):
                result = mock.Mock(returncode=0, stdout=output)
                with mock.patch("shutil.which", return_value="/usr/bin/busctl"), mock.patch("subprocess.run", return_value=result):
                    self.assertFalse(power.sleep_disabled())

    def test_other_users_and_other_programs_locks_dont_count(self):
        uid = os.getuid()
        rows = [
            ["handle-lid-switch", "wick", "why", "block", uid + 1, 10],
            ["handle-lid-switch", "gnome-shell", "why", "block", uid, 11],
            ["sleep", "wick", "why", "block", uid, 12],
            ["handle-lid-switch", "wick", "why", "delay", uid, 13],
        ]
        result = mock.Mock(returncode=0, stdout=json.dumps({"data": [rows]}))
        with mock.patch("shutil.which", return_value="/usr/bin/busctl"), mock.patch("subprocess.run", return_value=result):
            self.assertFalse(power.sleep_disabled())

        rows.append(["handle-lid-switch:sleep:idle", "wick", "why", "block", uid, 14])
        result = mock.Mock(returncode=0, stdout=json.dumps({"data": [rows]}))
        with mock.patch("shutil.which", return_value="/usr/bin/busctl"), mock.patch("subprocess.run", return_value=result):
            self.assertTrue(power.sleep_disabled())


class Launcher(unittest.TestCase):
    def test_uses_absolute_paths(self):
        from wick import desktop

        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_DATA_HOME": directory}):
            desktop.install_launcher("/home/me/.local/bin/wick")
            entry = (Path(directory) / "applications" / desktop.LAUNCHER).read_text(encoding="utf-8")
        self.assertIn('Exec="/home/me/.local/bin/wick" app', entry)
        self.assertIn("wick-awake.svg", entry)
        self.assertNotIn("Icon=wick\n", entry)


class PolkitRule(unittest.TestCase):
    def rule_for(self, version):
        from wick import desktop

        result = mock.Mock(stdout=version)
        with mock.patch("shutil.which", return_value="/usr/bin/pkaction"), mock.patch("subprocess.run", return_value=result):
            with mock.patch.dict(os.environ, {"USER": "ana"}):
                return desktop.polkit_rule_command()

    def test_modern_polkit_gets_javascript(self):
        for version in ("pkaction version 0.106", "pkaction version 124", "pkaction version 126"):
            with self.subTest(version=version):
                self.assertIn("polkit.addRule", self.rule_for(version))

    def test_it_can_be_pasted(self):
        # An indented heredoc terminator never closes, which would leave the documented fix broken.
        for version in ("pkaction version 126", "pkaction version 0.105"):
            with self.subTest(version=version):
                lines = self.rule_for(version).splitlines()
                self.assertEqual(lines[-1], "RULE")
                self.assertTrue(lines[0].startswith("cat > "))

    def test_old_polkit_gets_the_format_it_can_read(self):
        rule = self.rule_for("pkaction version 0.105")
        self.assertIn(".pkla", rule)
        self.assertIn("Identity=unix-user:ana", rule)


if __name__ == "__main__":
    unittest.main()
