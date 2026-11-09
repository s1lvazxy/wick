"""The panel and the top bar icon, for desktops that aren't GNOME. On GNOME, the extension does this job natively.

Same design as the Mac panel: a dark instrument, one colour that means "burning", and a ruler that is the wick.
GTK 3, because it's what AppIndicator is built against.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import importlib
import math
from pathlib import Path

import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from wick import agents, battery, core, durations, power, thermal  # noqa: E402
from wick.session import EndReason, Session, SessionStore, parse_iso  # noqa: E402

ASSETS = Path(__file__).resolve().parent / "assets"
_MIN_MINUTES = 5
_MAX_MINUTES = 720
_STEP = 5
_SPACING = 7.0
_PRESETS = (("30m", 30), ("1h", 60), ("2h", 120), ("4h", 240), ("8h", 480), ("∞", 0))
_FLOORS = (10, 20, 30, 50, None)
_SLOW_REFRESH_SECONDS = 5


class TrayUnavailable(Exception):
    pass


def _load_indicator():
    """Ayatana on Debian and Ubuntu, the original library elsewhere. Either way, optional."""
    for name in ("AyatanaAppIndicator3", "AppIndicator3"):
        try:
            gi.require_version(name, "0.1")
            return importlib.import_module(f"gi.repository.{name}")
        except (ValueError, ImportError):
            continue
    return None


CSS = b"""
.wick-window { background-color: transparent; }
.wick-panel {
    background-color: #141211;
    color: #F5F2EE;
    border-radius: 24px;
    border: 1px solid rgba(255, 255, 255, 0.10);
    padding: 14px 10px 10px;
    transition: background-image 400ms ease-out;
}
.wick-panel.awake {
    background-image: radial-gradient(ellipse at 50% 100%, rgba(255, 138, 61, 0.72) 0%, rgba(217, 66, 26, 0.42) 28%, rgba(217, 66, 26, 0.08) 58%, transparent 74%);
}
.wick-status { font-size: 13px; font-weight: 500; color: rgba(245, 242, 238, 0.68); }
.wick-status.problem { color: #FFC27A; }
.wick-dot { min-width: 6px; min-height: 6px; border-radius: 3px; background-color: rgba(245, 242, 238, 0.40); }
.wick-panel.awake .wick-dot { background-color: #FF8A3D; box-shadow: 0 0 8px #FF8A3D; }
.wick-clock { font-size: 56px; font-weight: 300; font-feature-settings: "tnum"; letter-spacing: -1.5px; color: #F5F2EE; }
.wick-caption { font-size: 12.5px; color: rgba(245, 242, 238, 0.68); }
.wick-play, .wick-play:hover, .wick-play:active {
    background-image: none;
    background-color: #F5F2EE;
    color: #1A1412;
    border: none;
    box-shadow: none;
    border-radius: 29px;
    min-width: 58px;
    min-height: 58px;
    padding: 0;
    font-size: 20px;
    transition: background-color 200ms ease-out;
}
.wick-panel.awake .wick-play { background-color: #FF8A3D; box-shadow: 0 0 22px rgba(255, 138, 61, 0.55); }
.wick-preset, .wick-preset:hover, .wick-preset:active {
    background-image: none;
    background-color: transparent;
    border: none;
    box-shadow: none;
    border-radius: 15px;
    color: rgba(245, 242, 238, 0.68);
    font-size: 13px;
    font-weight: 500;
    min-height: 30px;
    padding: 0;
}
.wick-preset:hover { color: #F5F2EE; }
.wick-preset.selected { background-color: rgba(255, 255, 255, 0.12); color: #F5F2EE; }
.wick-card { background-color: rgba(0, 0, 0, 0.22); border-radius: 14px; border: 1px solid rgba(255, 255, 255, 0.06); padding: 4px 12px; }
.wick-row { padding: 6px 0; }
.wick-row-title { font-size: 13px; font-weight: 500; color: #F5F2EE; }
.wick-row-detail { font-size: 11.5px; color: rgba(245, 242, 238, 0.68); }
.wick-separator { min-height: 1px; background-color: rgba(255, 255, 255, 0.10); }
switch { background-image: none; background-color: rgba(255, 255, 255, 0.16); border: none; border-radius: 12px; }
switch:checked { background-color: #FF8A3D; }
switch slider { background-image: none; background-color: #F5F2EE; border: none; border-radius: 10px; box-shadow: none; }
"""


class Ruler(Gtk.DrawingArea):
    """The ticks left of the needle are the time still to burn."""

    def __init__(self, on_scrub, on_commit) -> None:
        super().__init__()
        self.on_scrub = on_scrub
        self.on_commit = on_commit
        self.minutes = 120.0
        self.burning = False
        self.open_ended = False
        self.dragging = False
        self._drag_start = (0.0, 0.0)
        self.set_size_request(-1, 44)
        self.set_can_focus(True)
        self.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.SCROLL_MASK
            | Gdk.EventMask.SMOOTH_SCROLL_MASK
            | Gdk.EventMask.KEY_PRESS_MASK
        )
        self.connect("draw", self._draw)
        self.connect("button-press-event", self._press)
        self.connect("motion-notify-event", self._motion)
        self.connect("button-release-event", self._release)
        self.connect("scroll-event", self._scroll)
        self.connect("key-press-event", self._key)

    def show_minutes(self, minutes: float) -> None:
        if not self.dragging:
            self.minutes = minutes
            self.queue_draw()

    def _draw(self, _, context) -> None:
        width = self.get_allocated_width()
        height = self.get_allocated_height()
        center, middle = width / 2, height / 2
        per_minute = _SPACING / _STEP
        reach = center / per_minute
        first = max(0, math.floor((self.minutes - reach) / _STEP))
        last = min(_MAX_MINUTES // _STEP, math.ceil((self.minutes + reach) / _STEP))

        for tick in range(first, last + 1):
            minute = tick * _STEP
            x = round(center + (minute - self.minutes) * per_minute)
            # Fades out toward both edges.
            edge = min(x, width - x) / max(width * 0.14, 1)
            fade = max(0.0, min(edge, 1.0))
            if not self.open_ended and minute <= self.minutes + 0.001:
                red, green, blue, alpha = (1, 0.76, 0.48, 1) if self.burning else (0.96, 0.95, 0.93, 0.72)
            else:
                red, green, blue, alpha = (0.96, 0.95, 0.93, 0.2)
            context.set_source_rgba(red, green, blue, alpha * fade)
            tall = 26 if tick % 12 == 0 else 18 if tick % 6 == 0 else 12
            context.rectangle(x - 0.5, middle - tall / 2, 1.5 if tick % 12 == 0 else 1, tall)
            context.fill()

        if self.burning:
            context.set_source_rgba(1, 0.54, 0.24, 1)
        else:
            context.set_source_rgba(0.96, 0.95, 0.93, 1)
        context.rectangle(center - 1, middle - 18, 2, 36)
        context.fill()

    def _press(self, _, event) -> bool:
        self.grab_focus()
        self.dragging = True
        self._drag_start = (event.x, self.minutes)
        return True

    def _motion(self, _, event) -> bool:
        if self.dragging:
            start_x, start_minutes = self._drag_start
            moved = start_minutes - (event.x - start_x) / (_SPACING / _STEP)
            self.minutes = max(_MIN_MINUTES, min(moved, _MAX_MINUTES))
            self.on_scrub(self._snapped())
            self.queue_draw()
        return True

    def _release(self, *_) -> bool:
        if self.dragging:
            self.dragging = False
            self.minutes = self._snapped()
            self.queue_draw()
            self.on_commit(self.minutes)
        return True

    def _scroll(self, _, event) -> bool:
        direction = event.direction
        if direction == Gdk.ScrollDirection.SMOOTH:
            delta = event.delta_x or event.delta_y
        else:
            delta = 1 if direction in (Gdk.ScrollDirection.UP, Gdk.ScrollDirection.RIGHT) else -1
        if delta:
            self._step(_STEP if delta > 0 else -_STEP)
        return True

    def _key(self, _, event) -> bool:
        if event.keyval in (Gdk.KEY_Right, Gdk.KEY_Up):
            self._step(_STEP)
        elif event.keyval in (Gdk.KEY_Left, Gdk.KEY_Down):
            self._step(-_STEP)
        else:
            return False
        return True

    def _step(self, amount: int) -> None:
        self.minutes = max(_MIN_MINUTES, min(self._snapped() + amount, _MAX_MINUTES))
        self.queue_draw()
        self.on_commit(self.minutes)

    def _snapped(self) -> float:
        return max(_MIN_MINUTES, min(round(self.minutes / _STEP) * _STEP, _MAX_MINUTES))


class Panel(Gtk.Window):
    def __init__(self, executable: str, on_change) -> None:
        super().__init__(title="Wick")
        self.executable = executable
        self.on_change = on_change
        self.store = SessionStore()
        self.minutes = 120.0
        self.forever = False
        self.until_agents = False
        self.floor: int | None = 20
        self.problem: str | None = None
        self.scrubbing: float | None = None
        self.session: Session | None = None
        self.awake = False

        self.set_decorated(False)
        self.set_resizable(False)
        self.set_default_size(340, -1)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        visual = self.get_screen().get_rgba_visual()
        if visual and self.is_composited():
            self.set_visual(visual)
            self.set_app_paintable(True)
        self.get_style_context().add_class("wick-window")
        self.connect("key-press-event", self._on_key)
        self.connect("delete-event", lambda *_: self.hide() or True)
        self._build()

    def _on_key(self, _, event) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            self.hide()
            return True
        return False

    def _build(self) -> None:
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.root.get_style_context().add_class("wick-panel")
        self.root.set_size_request(340, -1)
        self.add(self.root)

        status = Gtk.Box(spacing=8, margin_start=8, margin_end=8)
        dot = Gtk.Box(valign=Gtk.Align.CENTER)
        dot.get_style_context().add_class("wick-dot")
        self.status_label = Gtk.Label(xalign=0, wrap=True, hexpand=True, max_width_chars=38)
        self.status_label.get_style_context().add_class("wick-status")
        close = Gtk.Button(label="×", relief=Gtk.ReliefStyle.NONE, tooltip_text="Close")
        close.get_style_context().add_class("wick-preset")
        close.set_size_request(30, -1)
        close.connect("clicked", lambda *_: self.hide())
        status.pack_start(dot, False, False, 0)
        status.pack_start(self.status_label, True, True, 0)
        status.pack_end(close, False, False, 0)
        self.root.pack_start(status, False, False, 0)

        hero = Gtk.Box(spacing=12, margin_start=8, margin_end=8)
        words = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        self.clock_label = Gtk.Label(xalign=0)
        self.clock_label.get_style_context().add_class("wick-clock")
        self.caption_label = Gtk.Label(xalign=0, ellipsize=3)
        self.caption_label.get_style_context().add_class("wick-caption")
        words.pack_start(self.clock_label, False, False, 0)
        words.pack_start(self.caption_label, False, False, 0)
        self.play = Gtk.Button(label="▶", valign=Gtk.Align.CENTER, tooltip_text="Keep awake")
        self.play.get_style_context().add_class("wick-play")
        self.play.connect("clicked", lambda *_: self.toggle())
        hero.pack_start(words, True, True, 0)
        hero.pack_end(self.play, False, False, 0)
        self.root.pack_start(hero, False, False, 0)

        self.ruler = Ruler(self._scrub, self._commit)
        self.root.pack_start(self.ruler, False, False, 0)

        presets = Gtk.Box(homogeneous=True, spacing=2)
        self.preset_buttons = []
        for label, minutes in _PRESETS:
            button = Gtk.Button(label=label)
            button.get_style_context().add_class("wick-preset")
            button.connect("clicked", lambda _, value=minutes: self._choose_preset(value))
            presets.pack_start(button, True, True, 0)
            self.preset_buttons.append((button, minutes))
        self.root.pack_start(presets, False, False, 0)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        card.get_style_context().add_class("wick-card")
        self.agent_detail, agent_row = self._row("Stop when agents finish")
        self.agent_switch = Gtk.Switch(valign=Gtk.Align.CENTER)
        self.agent_switch.connect("notify::active", self._toggle_agents)
        agent_row.pack_end(self.agent_switch, False, False, 0)
        card.pack_start(agent_row, False, False, 0)

        separator = Gtk.Box()
        separator.get_style_context().add_class("wick-separator")
        card.pack_start(separator, False, False, 0)

        self.battery_detail, self.battery_row = self._row("Stop at low battery")
        self.floor_button = Gtk.Button(label="20%", tooltip_text="Battery level to stop at")
        self.floor_button.get_style_context().add_class("wick-preset")
        self.floor_button.set_size_request(52, -1)
        self.floor_button.connect("clicked", lambda *_: self._cycle_floor())
        self.battery_row.pack_end(self.floor_button, False, False, 0)
        card.pack_start(self.battery_row, False, False, 0)

        self.battery_separator = Gtk.Box()
        self.battery_separator.get_style_context().add_class("wick-separator")
        card.pack_start(self.battery_separator, False, False, 0)

        # The one condition with nothing to switch: it's there to say so.
        self.heat_detail, heat_row = self._row("Stops if it gets hot")
        always = Gtk.Label(label="Always", valign=Gtk.Align.CENTER)
        always.get_style_context().add_class("wick-row-detail")
        heat_row.pack_end(always, False, False, 0)
        card.pack_start(heat_row, False, False, 0)
        self.root.pack_start(card, False, False, 0)

        quit_button = Gtk.Button(label="Quit Wick")
        quit_button.get_style_context().add_class("wick-preset")
        quit_button.connect("clicked", lambda *_: Gtk.main_quit())
        self.root.pack_start(quit_button, False, False, 0)

    def _row(self, title: str):
        row = Gtk.Box(spacing=8)
        row.get_style_context().add_class("wick-row")
        words = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        heading = Gtk.Label(label=title, xalign=0)
        heading.get_style_context().add_class("wick-row-title")
        detail = Gtk.Label(xalign=0, ellipsize=3, max_width_chars=30)
        detail.get_style_context().add_class("wick-row-detail")
        words.pack_start(heading, False, False, 0)
        words.pack_start(detail, False, False, 0)
        row.pack_start(words, True, True, 0)
        return detail, row

    # Actions

    def toggle(self) -> None:
        self.problem = None
        try:
            if self.awake:
                core.Wick.stop(EndReason.STOPPED_BY_USER, store=self.store)
            else:
                ends = None
                if not self.forever:
                    ends = (datetime.now(timezone.utc) + timedelta(minutes=self.minutes)).isoformat()
                core.Wick.start(
                    Session(endsAt=ends, untilAgentsFinish=self.until_agents, batteryFloor=self.floor),
                    executable=self.executable,
                    store=self.store,
                )
        except power.PowerError as error:
            self.problem = str(error)
        self.refresh(slow=True)
        self.on_change()

    def _update_session(self, change) -> None:
        if self.session is not None:
            self.store.update(change)
            self.refresh()
            self.on_change()

    def _scrub(self, minutes: float) -> None:
        self.scrubbing = minutes
        self.refresh()

    def _commit(self, minutes: float) -> None:
        self.scrubbing = None
        self.minutes = minutes
        self.forever = False
        ends = (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()
        self._update_session(lambda session: setattr(session, "endsAt", ends))
        self.refresh()

    def _choose_preset(self, minutes: int) -> None:
        if minutes == 0:
            self.forever = True
            self._update_session(lambda session: setattr(session, "endsAt", None))
            self.refresh()
        else:
            self._commit(float(minutes))

    def _toggle_agents(self, switch, _) -> None:
        self.until_agents = switch.get_active()
        self._update_session(lambda session: setattr(session, "untilAgentsFinish", self.until_agents))

    def _cycle_floor(self) -> None:
        position = _FLOORS.index(self.floor) if self.floor in _FLOORS else -1
        self.floor = _FLOORS[(position + 1) % len(_FLOORS)]
        self._update_session(lambda session: setattr(session, "batteryFloor", self.floor))
        self.refresh()

    # Display

    def refresh(self, slow: bool = False) -> None:
        self.session = self.store.load()
        if slow:
            core.Wick.reconcile(self.executable, store=self.store)
            self.session = self.store.load()
            self.awake = self.session is not None and power.sleep_disabled()
            self._refresh_slow_details()
        elif self.session is None:
            self.awake = False

        # A session can start from the terminal, so what it says wins over what was last chosen here.
        if self.awake and self.session:
            self.floor = self.session.batteryFloor
            self.until_agents = self.session.untilAgentsFinish
            if self.agent_switch.get_active() != self.until_agents:
                self.agent_switch.set_active(self.until_agents)

        now = datetime.now(timezone.utc)
        ends = parse_iso(self.session.endsAt) if self.awake and self.session else None
        remaining = (ends - now).total_seconds() if ends else None

        style = self.root.get_style_context()
        (style.add_class if self.awake else style.remove_class)("awake")

        status_style = self.status_label.get_style_context()
        (status_style.add_class if self.problem else status_style.remove_class)("problem")
        self.status_label.set_text(self.problem or self._status_text())

        self.play.set_label("■" if self.awake else "▶")
        self.play.set_tooltip_text("Stop" if self.awake else "Keep awake")

        open_ended = (self.awake and ends is None) or (not self.awake and self.forever)
        if self.scrubbing is not None:
            self.clock_label.set_text(_hours_and_minutes(self.scrubbing))
        elif remaining is not None:
            self.clock_label.set_text(durations.clock(remaining))
        elif open_ended:
            self.clock_label.set_text("∞")
        else:
            self.clock_label.set_text(_hours_and_minutes(self.minutes))
        self.caption_label.set_text(self._caption(now, ends, open_ended))

        self.ruler.burning = self.awake
        self.ruler.open_ended = open_ended and self.scrubbing is None
        self.ruler.show_minutes(max(_MIN_MINUTES, remaining / 60) if remaining is not None else self.minutes)

        for button, minutes in self.preset_buttons:
            selected = (minutes == 0 and open_ended) or (not self.awake and not self.forever and minutes == self.minutes)
            button_style = button.get_style_context()
            (button_style.add_class if selected else button_style.remove_class)("selected")

        self.floor_button.set_label(f"{self.floor}%" if self.floor else "Off")

    def _status_text(self) -> str:
        if self.awake:
            return "Awake with the lid closed"
        last = self.store.last_end()
        if last and last.get("reason") not in (None, EndReason.STOPPED_BY_USER.value):
            at = parse_iso(last.get("at"))
            if at and (datetime.now(timezone.utc) - at).total_seconds() < 43200:
                try:
                    return EndReason(last["reason"]).sentence
                except ValueError:
                    pass
        return "Sleeps when the lid closes"

    def _caption(self, now: datetime, ends: datetime | None, open_ended: bool) -> str:
        if self.scrubbing is not None:
            ends = now + timedelta(minutes=self.scrubbing)
        elif ends is None and not open_ended:
            ends = now + timedelta(minutes=self.minutes)

        if ends is not None:
            clock = ends.astimezone().strftime("%H:%M")
            text = f"until {clock}" if ends.astimezone().date() == now.astimezone().date() else f"until {clock} tomorrow"
        elif self.session is not None and self.session.heldPIDs:
            text = "while a command runs"
        else:
            text = "until you stop it"
        return f"{text} or agents finish" if self.until_agents else text

    def _refresh_slow_details(self) -> None:
        running = agents.running() if self.get_visible() else []
        if not running:
            self.agent_detail.set_text("No agents running")
        elif len(running) <= 2:
            self.agent_detail.set_text(f"{' and '.join(running)} running")
        else:
            self.agent_detail.set_text(f"{running[0]} and {len(running) - 1} others running")

        current = battery.Battery.current()
        self.battery_row.set_visible(current is not None)
        self.battery_separator.set_visible(current is not None)
        if current:
            self.battery_detail.set_text(f"{current.percent}%, {'on battery' if current.is_discharging else 'plugged in'}")

        self.heat_detail.set_text(thermal.Heat.current(always_ask_lid=False).summary)


def _hours_and_minutes(minutes: float) -> str:
    return f"{int(minutes) // 60}:{int(minutes) % 60:02d}"


class App:
    def __init__(self, executable: str) -> None:
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        screen = Gdk.Screen.get_default()
        if screen is None:
            raise TrayUnavailable("There's no display to show the panel on.")
        Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.panel = Panel(executable, self._update_indicator)
        self.indicator = None
        self.stop_item = None

        library = _load_indicator()
        if library is not None:
            self.indicator = library.Indicator.new(
                "wick", str(ASSETS / "wick-idle.svg"), library.IndicatorCategory.APPLICATION_STATUS
            )
            self.indicator.set_status(library.IndicatorStatus.ACTIVE)
            self.indicator.set_title("Wick")
            self.indicator.set_menu(self._build_menu())
        else:
            # Without an icon to come back through, closing the panel has to mean quitting.
            self.panel.connect("hide", lambda *_: Gtk.main_quit())

        self._ticks = 0
        self._tick()
        GLib.timeout_add_seconds(1, self._tick)

    def _build_menu(self) -> Gtk.Menu:
        menu = Gtk.Menu()
        open_item = Gtk.MenuItem(label="Open Wick")
        open_item.connect("activate", lambda *_: self.show_panel())
        menu.append(open_item)
        self.stop_item = Gtk.MenuItem(label="Stop")
        self.stop_item.connect("activate", lambda *_: self.panel.toggle() if self.panel.awake else None)
        menu.append(self.stop_item)
        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit Wick")
        quit_item.connect("activate", lambda *_: Gtk.main_quit())
        menu.append(quit_item)
        menu.show_all()
        self.indicator.set_secondary_activate_target(open_item)
        return menu

    def show_panel(self) -> None:
        self.panel.show_all()
        # After showing, because agents are only scanned for while the panel is visible.
        self.panel.refresh(slow=True)
        self.panel.present()

    def _tick(self) -> bool:
        # The clock is only a file read. Asking logind and scanning processes waits for the slower beat.
        slow = self._ticks % _SLOW_REFRESH_SECONDS == 0
        self._ticks += 1
        self.panel.refresh(slow=slow)
        self._update_indicator()
        return True

    def _update_indicator(self) -> None:
        if self.indicator is None:
            return
        session = self.panel.session if self.panel.awake else None
        icon = "wick-awake.svg" if session else "wick-idle.svg"
        self.indicator.set_icon_full(str(ASSETS / icon), "Wick, awake" if session else "Wick")
        label = ""
        if session:
            ends = parse_iso(session.endsAt)
            label = durations.compact((ends - datetime.now(timezone.utc)).total_seconds()) if ends else "∞"
        self.indicator.set_label(label, "10h 00m")
        if self.stop_item is not None:
            self.stop_item.set_sensitive(bool(session))


def launch_app(executable: str) -> None:
    app = App(executable)
    app.show_panel()
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass
