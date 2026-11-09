// The top bar icon and panel for GNOME. It holds no state of its own: `wick status --json` says what's going on,
// and `wick on` and `wick off` change it, so the guard and its safety rules work the same with or without it.

import Clutter from 'gi://Clutter';
import Cairo from 'gi://cairo';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PRESETS = [
    {label: '30m', minutes: 30},
    {label: '1h', minutes: 60},
    {label: '2h', minutes: 120},
    {label: '4h', minutes: 240},
    {label: '8h', minutes: 480},
    {label: '∞', minutes: 0},
];
const POLL_SECONDS = 5;
const MIN_MINUTES = 5;
const MAX_MINUTES = 720;
const STEP = 5;
const SPACING = 7;

function clock(seconds) {
    const total = Math.max(0, Math.ceil(seconds));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const rest = String(total % 60).padStart(2, '0');
    return hours > 0 ? `${hours}:${String(minutes).padStart(2, '0')}:${rest}` : `${minutes}:${rest}`;
}

function compact(seconds) {
    if (seconds < 60)
        return '<1m';
    const minutes = Math.ceil(seconds / 60);
    return minutes >= 60
        ? `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m`
        : `${minutes}m`;
}

function hoursAndMinutes(minutes) {
    return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, '0')}`;
}

function findWick() {
    // GNOME Shell's PATH often leaves out ~/.local/bin, which is where pipx puts it.
    return GLib.find_program_in_path('wick') ??
        [`${GLib.get_home_dir()}/.local/bin/wick`].find(path => GLib.file_test(path, GLib.FileTest.IS_EXECUTABLE)) ??
        null;
}

const END_SENTENCES = {
    timeUp: "Time's up. Sleep is back to normal.",
    agentsFinished: 'Agents finished. Sleep is back to normal.',
    commandFinished: 'Command finished. Sleep is back to normal.',
    lowBattery: 'Stopped to protect the battery.',
    overheating: 'Stopped to let the laptop cool down.',
    stoppedExternally: 'The lid lock ended outside Wick.',
};

// `orientation` replaced `vertical` in GNOME 48, and the old name only warns for so long.
function column(properties) {
    const box = new St.BoxLayout(properties);
    if ('orientation' in box)
        box.orientation = Clutter.Orientation.VERTICAL;
    else
        box.vertical = true;
    return box;
}

const WickIndicator = GObject.registerClass(
class WickIndicator extends PanelMenu.Button {
    _init(path) {
        super._init(0.0, 'Wick');
        this._idleIcon = Gio.icon_new_for_string(`${path}/icons/wick-idle.svg`);
        this._awakeIcon = Gio.icon_new_for_string(`${path}/icons/wick-awake.svg`);
        this._minutes = 120;
        this._untilAgents = false;
        this._state = null;
        this._problem = null;
        this._scrub = null;
        this._cancellable = new Gio.Cancellable();

        const box = new St.BoxLayout({style_class: 'panel-status-indicators-box'});
        this._icon = new St.Icon({gicon: this._idleIcon, icon_size: 22, y_align: Clutter.ActorAlign.CENTER});
        this._topLabel = new St.Label({style_class: 'wick-top-label', y_align: Clutter.ActorAlign.CENTER, visible: false});
        box.add_child(this._icon);
        box.add_child(this._topLabel);
        this.add_child(box);

        this._buildMenu();
        this.menu.connect('open-state-changed', (_, isOpen) => {
            if (isOpen)
                this._poll();
        });

        this._poll();
        this._pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, POLL_SECONDS, () => {
            this._poll();
            return GLib.SOURCE_CONTINUE;
        });
        this._clockId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
            this._render();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _buildMenu() {
        const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, style_class: 'wick-menu-item'});
        this.menu.addMenuItem(item);
        this.menu.box.add_style_class_name('wick-menu-box');

        this._panel = column({style_class: 'wick-panel', x_expand: true});
        item.add_child(this._panel);

        const statusRow = new St.BoxLayout({style_class: 'wick-status-row'});
        this._dot = new St.Widget({style_class: 'wick-dot', y_align: Clutter.ActorAlign.CENTER});
        this._status = new St.Label({style_class: 'wick-status', y_align: Clutter.ActorAlign.CENTER, x_expand: true});
        this._status.clutter_text.line_wrap = true;
        statusRow.add_child(this._dot);
        statusRow.add_child(this._status);
        this._panel.add_child(statusRow);

        const hero = new St.BoxLayout({style_class: 'wick-hero'});
        const words = column({x_expand: true});
        this._clock = new St.Label({style_class: 'wick-clock'});
        this._caption = new St.Label({style_class: 'wick-caption'});
        words.add_child(this._clock);
        words.add_child(this._caption);
        hero.add_child(words);
        this._play = new St.Button({style_class: 'wick-play', can_focus: true, y_align: Clutter.ActorAlign.CENTER});
        this._playIcon = new St.Icon({icon_name: 'media-playback-start-symbolic', icon_size: 20});
        this._play.set_child(this._playIcon);
        this._play.connect('clicked', () => this._toggle());
        hero.add_child(this._play);
        this._panel.add_child(hero);

        this._ruler = new St.DrawingArea({style_class: 'wick-ruler', reactive: true, can_focus: true, x_expand: true, accessible_name: 'Duration'});
        this._ruler.connect('repaint', area => this._drawRuler(area));
        this._ruler.connect('button-press-event', (_, event) => this._rulerPress(event));
        this._ruler.connect('motion-event', (_, event) => this._rulerMotion(event));
        this._ruler.connect('button-release-event', () => this._rulerRelease());
        this._ruler.connect('scroll-event', (_, event) => this._rulerScroll(event));
        this._ruler.connect('key-press-event', (_, event) => this._rulerKey(event));
        this._panel.add_child(this._ruler);

        const presets = new St.BoxLayout({style_class: 'wick-presets', x_expand: true});
        this._presets = PRESETS.map(preset => {
            const button = new St.Button({label: preset.label, style_class: 'wick-preset', can_focus: true, x_expand: true});
            button.connect('clicked', () => this._choose(preset.minutes));
            presets.add_child(button);
            return {button, minutes: preset.minutes};
        });
        this._panel.add_child(presets);

        const card = column({style_class: 'wick-card'});
        const agentRow = new St.BoxLayout({style_class: 'wick-row'});
        const agentWords = column({x_expand: true});
        agentWords.add_child(new St.Label({text: 'Stop when agents finish', style_class: 'wick-row-title'}));
        this._agentDetail = new St.Label({style_class: 'wick-row-detail'});
        agentWords.add_child(this._agentDetail);
        agentRow.add_child(agentWords);
        this._agentButton = new St.Button({style_class: 'wick-toggle', can_focus: true, toggle_mode: true, y_align: Clutter.ActorAlign.CENTER});
        this._agentKnob = new St.Widget({style_class: 'wick-toggle-knob', x_align: Clutter.ActorAlign.CENTER});
        this._agentButton.set_child(this._agentKnob);
        this._agentButton.connect('clicked', () => {
            this._untilAgents = this._agentButton.checked;
            if (this._runningSession())
                this._run(['set', '--agents', this._untilAgents ? 'on' : 'off']);
            this._render();
        });
        agentRow.add_child(this._agentButton);
        card.add_child(agentRow);

        this._batteryRow = new St.BoxLayout({style_class: 'wick-row', visible: false});
        const batteryWords = column({x_expand: true});
        batteryWords.add_child(new St.Label({text: 'Stops at low battery', style_class: 'wick-row-title'}));
        this._batteryDetail = new St.Label({style_class: 'wick-row-detail'});
        batteryWords.add_child(this._batteryDetail);
        this._batteryRow.add_child(batteryWords);
        card.add_child(this._batteryRow);

        // The one condition with nothing to switch: it's there to say so.
        this._heatRow = new St.BoxLayout({style_class: 'wick-row', visible: false});
        const heatWords = column({x_expand: true});
        heatWords.add_child(new St.Label({text: 'Stops if it gets hot', style_class: 'wick-row-title'}));
        this._heatDetail = new St.Label({style_class: 'wick-row-detail'});
        heatWords.add_child(this._heatDetail);
        this._heatRow.add_child(heatWords);
        this._heatRow.add_child(new St.Label({text: 'Always', style_class: 'wick-row-detail', y_align: Clutter.ActorAlign.CENTER}));
        card.add_child(this._heatRow);
        this._panel.add_child(card);
    }

    // The ruler. The ticks left of the needle are the time still to burn.

    _rulerMinutes() {
        if (this._scrub !== null)
            return this._scrub;
        const session = this._runningSession();
        if (session?.endsAt)
            return Math.max(MIN_MINUTES, (new Date(session.endsAt).getTime() - Date.now()) / 60000);
        return this._minutes > 0 ? this._minutes : 120;
    }

    _drawRuler(area) {
        const cr = area.get_context();
        const [width, height] = area.get_surface_size();
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const session = this._runningSession();
        const openEnded = this._scrub === null && (session ? !session.endsAt : this._minutes === 0);
        const value = this._rulerMinutes();
        const center = width / 2;
        const middle = height / 2;
        const perMinute = (SPACING / STEP) * scale;
        const reach = center / perMinute;
        const first = Math.max(0, Math.floor((value - reach) / STEP));
        const last = Math.min(MAX_MINUTES / STEP, Math.ceil((value + reach) / STEP));

        for (let tick = first; tick <= last; tick++) {
            const minute = tick * STEP;
            const x = Math.round(center + (minute - value) * perMinute);
            const fade = Math.max(0, Math.min(Math.min(x, width - x) / (width * 0.14), 1));
            const lit = !openEnded && minute <= value + 0.001;
            if (lit && session)
                cr.setSourceRGBA(1, 0.76, 0.48, fade);
            else if (lit)
                cr.setSourceRGBA(0.96, 0.95, 0.93, 0.72 * fade);
            else
                cr.setSourceRGBA(0.96, 0.95, 0.93, 0.2 * fade);
            const tall = (tick % 12 === 0 ? 26 : tick % 6 === 0 ? 18 : 12) * scale;
            cr.rectangle(x, middle - tall / 2, (tick % 12 === 0 ? 1.5 : 1) * scale, tall);
            cr.fill();
        }

        if (session)
            cr.setSourceRGBA(1, 0.54, 0.24, 1);
        else
            cr.setSourceRGBA(0.96, 0.95, 0.93, 1);
        cr.rectangle(center - scale, middle - 18 * scale, 2 * scale, 36 * scale);
        cr.fill();
        cr.$dispose();
    }

    _rulerPress(event) {
        this._dragStart = {x: event.get_coords()[0], minutes: this._rulerMinutes()};
        this._grab = global.stage.grab(this._ruler);
        return Clutter.EVENT_STOP;
    }

    _rulerMotion(event) {
        if (!this._dragStart)
            return Clutter.EVENT_PROPAGATE;
        const moved = this._dragStart.minutes - (event.get_coords()[0] - this._dragStart.x) / (SPACING / STEP);
        this._scrub = Math.max(MIN_MINUTES, Math.min(moved, MAX_MINUTES));
        this._render();
        return Clutter.EVENT_STOP;
    }

    _rulerRelease() {
        this._grab?.dismiss();
        this._grab = null;
        this._dragStart = null;
        if (this._scrub !== null) {
            const snapped = this._snap(this._scrub);
            this._scrub = null;
            this._choose(snapped);
        }
        return Clutter.EVENT_STOP;
    }

    _rulerScroll(event) {
        const direction = event.get_scroll_direction();
        if (direction === Clutter.ScrollDirection.UP || direction === Clutter.ScrollDirection.RIGHT)
            this._choose(this._snap(this._rulerMinutes() + STEP));
        else if (direction === Clutter.ScrollDirection.DOWN || direction === Clutter.ScrollDirection.LEFT)
            this._choose(this._snap(this._rulerMinutes() - STEP));
        return Clutter.EVENT_STOP;
    }

    _rulerKey(event) {
        const key = event.get_key_symbol();
        if (key === Clutter.KEY_Right || key === Clutter.KEY_Up)
            this._choose(this._snap(this._rulerMinutes() + STEP));
        else if (key === Clutter.KEY_Left || key === Clutter.KEY_Down)
            this._choose(this._snap(this._rulerMinutes() - STEP));
        else
            return Clutter.EVENT_PROPAGATE;
        return Clutter.EVENT_STOP;
    }

    _snap(minutes) {
        return Math.max(MIN_MINUTES, Math.min(Math.round(minutes / STEP) * STEP, MAX_MINUTES));
    }

    _choose(minutes) {
        this._minutes = minutes;
        this._problem = null;
        // `wick set` refuses if the session has ended, so this view being seconds old can't revive one.
        if (this._runningSession())
            this._run(['set', minutes > 0 ? `${minutes}m` : 'forever']);
        this._render();
    }

    _runningSession() {
        return this._state?.sleepDisabled ? this._state.session : null;
    }

    _toggle() {
        this._problem = null;
        if (this._state?.sleepDisabled)
            this._run(['off']);
        else
            this._start();
    }

    _start() {
        const args = ['on'];
        if (this._minutes > 0)
            args.push(`${this._minutes}m`);
        if (this._untilAgents)
            args.push('--agents');
        this._run(args);
    }

    _run(args) {
        const wick = findWick();
        if (!wick) {
            this._problem = "Can't find the wick command. Install it, then reopen this menu.";
            this._render();
            return;
        }
        try {
            const process = Gio.Subprocess.new([wick, ...args], Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_PIPE);
            process.communicate_utf8_async(null, this._cancellable, (source, result) => {
                try {
                    const [, , stderr] = source.communicate_utf8_finish(result);
                    if (!source.get_successful())
                        this._problem = (stderr ?? '').replace(/^wick: /, '').trim() || 'That didn\'t work.';
                    this._poll();
                } catch (error) {
                    if (!error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        logError(error, 'Wick');
                }
            });
        } catch (error) {
            this._problem = error.message;
            this._render();
        }
    }

    _poll() {
        const wick = findWick();
        if (!wick) {
            this._state = null;
            this._render();
            return;
        }
        try {
            const process = Gio.Subprocess.new([wick, 'status', '--json'], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
            process.communicate_utf8_async(null, this._cancellable, (source, result) => {
                try {
                    const [, stdout] = source.communicate_utf8_finish(result);
                    this._state = source.get_successful() ? JSON.parse(stdout) : null;
                    this._adoptRunningSession();
                    this._render();
                } catch (error) {
                    if (!error.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                        logError(error, 'Wick');
                }
            });
        } catch (error) {
            logError(error, 'Wick');
        }
    }

    // A session can start from the terminal, so what it says wins over what was last chosen here.
    _adoptRunningSession() {
        const session = this._runningSession();
        if (!session)
            return;
        this._untilAgents = session.untilAgentsFinish;
        this._agentButton.checked = this._untilAgents;
        const remaining = session.endsAt ? (new Date(session.endsAt).getTime() - Date.now()) / 60000 : 0;
        this._minutes = session.endsAt ? Math.max(1, Math.ceil(remaining)) : 0;
    }

    _render() {
        const session = this._runningSession();
        const awake = Boolean(session);
        const remaining = session?.endsAt ? (new Date(session.endsAt).getTime() - Date.now()) / 1000 : null;

        this._icon.gicon = awake ? this._awakeIcon : this._idleIcon;
        this._topLabel.visible = awake;
        this._topLabel.text = remaining !== null ? compact(remaining) : '∞';

        const toggleStyle = (actor, name, on) => (on ? actor.add_style_class_name(name) : actor.remove_style_class_name(name));
        toggleStyle(this._panel, 'awake', awake);
        toggleStyle(this._status, 'problem', Boolean(this._problem));
        this._status.text = this._problem ?? this._statusText(awake);

        this._playIcon.icon_name = awake ? 'media-playback-stop-symbolic' : 'media-playback-start-symbolic';

        const openEnded = awake ? remaining === null : this._minutes === 0;
        if (this._scrub !== null)
            this._clock.text = hoursAndMinutes(this._snap(this._scrub));
        else if (remaining !== null)
            this._clock.text = clock(remaining);
        else if (openEnded)
            this._clock.text = '∞';
        else
            this._clock.text = hoursAndMinutes(this._minutes);

        this._caption.text = this._captionText(session, remaining, openEnded);
        this._ruler.queue_repaint();

        this._presets.forEach(({button, minutes}) => {
            const selected = awake ? minutes === 0 && openEnded : minutes === this._minutes;
            toggleStyle(button, 'selected', selected);
        });

        toggleStyle(this._agentButton, 'on', this._untilAgents);
        this._agentKnob.translation_x = this._untilAgents ? 7 : -7;
        const agents = this._state?.agents ?? [];
        this._agentDetail.text = agents.length === 0
            ? 'No agents running'
            : agents.length <= 2 ? `${agents.join(' and ')} running` : `${agents[0]} and ${agents.length - 1} others running`;

        const battery = this._state?.battery;
        this._batteryRow.visible = Boolean(battery);
        if (battery) {
            const state = battery.isDischarging ? 'on battery' : 'plugged in';
            const floor = session ? session.batteryFloor : 20;
            this._batteryDetail.text = floor ? `${battery.percent}%, ${state}. Stops at ${floor}%` : `${battery.percent}%, ${state}`;
        }

        // An older `wick` on the PATH doesn't report heat, and a row with nothing to say is worse than no row.
        const heat = this._state?.heat;
        this._heatRow.visible = Boolean(heat);
        if (heat) {
            const known = typeof heat.batteryCelsius === 'number';
            this._heatDetail.text = known ? `${heat.word}, battery ${Math.round(heat.batteryCelsius)}°C` : heat.word;
        }
    }

    _statusText(awake) {
        if (awake)
            return 'Awake with the lid closed';
        if (!findWick())
            return "Can't find the wick command";
        const end = this._state?.lastEnd;
        const recent = end && (Date.now() - new Date(end.at).getTime()) < 12 * 3600 * 1000;
        return (recent && END_SENTENCES[end.reason]) || 'Sleeps when the lid closes';
    }

    _captionText(session, remaining, openEnded) {
        let text;
        if (openEnded && session?.heldPIDs?.length)
            text = 'while a command runs';
        else if (openEnded)
            text = 'until you stop it';
        else {
            const seconds = remaining ?? this._minutes * 60;
            const end = GLib.DateTime.new_now_local().add_seconds(seconds);
            const sameDay = end.get_day_of_year() === GLib.DateTime.new_now_local().get_day_of_year();
            text = `until ${end.format('%H:%M')}${sameDay ? '' : ' tomorrow'}`;
        }
        return (session ? session.untilAgentsFinish : this._untilAgents) ? `${text} or agents finish` : text;
    }

    destroy() {
        this._grab?.dismiss();
        this._cancellable.cancel();
        for (const id of [this._pollId, this._clockId]) {
            if (id)
                GLib.source_remove(id);
        }
        this._pollId = 0;
        this._clockId = 0;
        super.destroy();
    }
});

export default class WickExtension extends Extension {
    enable() {
        this._indicator = new WickIndicator(this.path);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
