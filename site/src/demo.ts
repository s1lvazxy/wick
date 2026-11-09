import * as session from "./session";

// A working copy of the app's panel, in the browser. The ruler uses the same values as RulerNSView in the app:
// 7 points per 5 minutes, a critically damped spring, Apple's momentum projection, and resistance past each end.

const STEP = 5;
const SPACING = 7;
const MIN = 5;
const MAX = 720;
const POINTS_PER_MINUTE = SPACING / STEP;
const DECELERATION = 0.998;
const OMEGA = (2 * Math.PI) / 0.32;

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);
const snap = (value: number) => clamp(Math.round(value / STEP) * STEP, MIN, MAX);

function hoursAndMinutes(minutes: number) {
  return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}`;
}

function spoken(minutes: number) {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  const parts = [];
  if (h) parts.push(`${h} hour${h === 1 ? "" : "s"}`);
  if (m) parts.push(`${m} minutes`);
  return parts.join(" ") || "0 minutes";
}

function rubberBand(raw: number) {
  const bound = raw < MIN ? MIN : raw > MAX ? MAX : raw;
  const overshoot = raw - bound;
  if (overshoot === 0) return raw;
  return bound + (overshoot * 60 * 0.55) / (60 + 0.55 * Math.abs(overshoot));
}

export function mountDemo() {
  const panel = document.querySelector<HTMLElement>("#demo");
  const canvas = document.querySelector<HTMLCanvasElement>("#demo-ruler");
  const time = document.querySelector<HTMLElement>("#demo-time");
  const caption = document.querySelector<HTMLElement>("#demo-caption");
  const status = document.querySelector<HTMLElement>("#demo-status");
  const play = document.querySelector<HTMLButtonElement>("#demo-play");
  const toggle = document.querySelector<HTMLButtonElement>("#demo-switch");
  const context = canvas?.getContext("2d");
  if (!panel || !canvas || !context || !time || !caption || !status || !play || !toggle) return;

  const reducesMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const presets = [...panel.querySelectorAll<HTMLButtonElement>("[data-minutes]")];

  let value = 120;
  let target = 120;
  let velocity = 0;
  let selected = 120;
  let endsAt: number | null = null;
  let isDragging = false;
  let ownsMotion = false;
  let frame = 0;
  let lastFrame = 0;
  let width = 0;
  let countdown = 0;

  function draw() {
    const ratio = devicePixelRatio || 1;
    const height = 44;
    if (canvas!.width !== Math.round(width * ratio)) {
      canvas!.width = Math.round(width * ratio);
      canvas!.height = height * ratio;
    }
    const g = context!;
    g.setTransform(ratio, 0, 0, ratio, 0, 0);
    g.clearRect(0, 0, width, height);

    const center = width / 2;
    const mid = height / 2;
    const isAwake = endsAt !== null;
    const reach = center / POINTS_PER_MINUTE;
    const first = Math.max(0, Math.floor((value - reach) / STEP));
    const last = Math.min(MAX / STEP, Math.ceil((value + reach) / STEP));

    for (let tick = first; tick <= last; tick++) {
      const minute = tick * STEP;
      const x = Math.round((center + (minute - value) * POINTS_PER_MINUTE) * ratio) / ratio;
      const isHour = tick % 12 === 0;
      const tall = isHour ? 26 : tick % 6 === 0 ? 18 : 12;
      const isLit = minute <= value + 0.001;
      g.fillStyle = isLit
        ? isAwake
          ? "rgb(255 194 122)"
          : "rgb(245 242 238 / 72%)"
        : "rgb(245 242 238 / 20%)";
      const w = isHour ? 1.5 : 1;
      g.fillRect(x - w / 2, mid - tall / 2, w, tall);
    }

    g.save();
    if (isAwake) {
      g.shadowColor = "rgb(255 138 61 / 95%)";
      g.shadowBlur = 10;
    }
    g.fillStyle = isAwake ? "#ff8a3d" : "#f5f2ee";
    g.beginPath();
    g.roundRect(center - 1, mid - 18, 2, 36, 1);
    g.fill();
    g.restore();
  }

  function shownMinutes() {
    return snap(value);
  }

  function updateText() {
    if (endsAt !== null && !isDragging && !ownsMotion) {
      time!.textContent = session.clock(endsAt - Date.now());
    } else if (endsAt !== null) {
      time!.textContent = hoursAndMinutes(shownMinutes());
    } else {
      time!.textContent = hoursAndMinutes(shownMinutes());
    }
    caption!.textContent = `for the next ${spoken(ownsMotion || isDragging ? shownMinutes() : selected)}`;
  }

  function updatePresets() {
    for (const preset of presets) {
      const isCurrent = endsAt === null && Number(preset.dataset.minutes) === selected;
      preset.setAttribute("aria-pressed", String(isCurrent));
    }
    canvas!.setAttribute("aria-valuenow", String(selected));
    canvas!.setAttribute("aria-valuetext", spoken(selected));
  }

  function commit(minutes: number) {
    selected = minutes;
    session.setMinutes(minutes);
    updatePresets();
  }

  function step(now: number) {
    frame = 0;
    const elapsed = lastFrame ? Math.min((now - lastFrame) / 1000, 1 / 30) : 1 / 60;
    lastFrame = now;
    velocity += (-OMEGA * OMEGA * (value - target) - 2 * OMEGA * velocity) * elapsed;
    value += velocity * elapsed;

    if (Math.abs(value - target) < 0.02 && Math.abs(velocity) < 0.2) {
      value = target;
      velocity = 0;
      ownsMotion = false;
      lastFrame = 0;
    } else {
      frame = requestAnimationFrame(step);
    }
    draw();
    updateText();
  }

  function settle(destination: number, releaseVelocity: number) {
    target = snap(destination);
    velocity = releaseVelocity;
    commit(target);
    if (reducesMotion) {
      value = target;
      velocity = 0;
      ownsMotion = false;
      draw();
      updateText();
    } else if (!frame) {
      ownsMotion = true;
      lastFrame = 0;
      frame = requestAnimationFrame(step);
    }
  }

  // Dragging: 1:1 with the pointer, then velocity carries into the spring.
  let startX = 0;
  let startValue = 0;
  let moved = false;
  let samples: { t: number; x: number }[] = [];

  canvas.addEventListener("pointerdown", (event) => {
    canvas.setPointerCapture(event.pointerId);
    cancelAnimationFrame(frame);
    frame = 0;
    isDragging = true;
    ownsMotion = true;
    moved = false;
    velocity = 0;
    startX = event.clientX;
    startValue = value;
    samples = [{ t: event.timeStamp, x: event.clientX }];
  });

  canvas.addEventListener("pointermove", (event) => {
    if (!isDragging) return;
    if (!moved && Math.abs(event.clientX - startX) < 2) return;
    moved = true;
    samples.push({ t: event.timeStamp, x: event.clientX });
    samples = samples.filter((sample) => event.timeStamp - sample.t <= 100);
    value = rubberBand(startValue - (event.clientX - startX) / POINTS_PER_MINUTE);
    draw();
    updateText();
  });

  function endDrag(event: PointerEvent) {
    if (!isDragging) return;
    isDragging = false;
    if (!moved) {
      const box = canvas!.getBoundingClientRect();
      settle(value + (event.clientX - box.left - box.width / 2) / POINTS_PER_MINUTE, 0);
      return;
    }
    // Only recent movement counts: holding still before letting go must not throw the ruler.
    const recent = samples.filter((sample) => event.timeStamp - sample.t <= 100);
    const first = recent[0];
    const last = recent[recent.length - 1];
    const seconds = first && last ? (last.t - first.t) / 1000 : 0;
    const pointsPerSecond = seconds > 0 ? (last.x - first.x) / seconds : 0;
    const release = -pointsPerSecond / POINTS_PER_MINUTE;
    settle(value + (release / 1000) * (DECELERATION / (1 - DECELERATION)), release);
  }

  canvas.addEventListener("pointerup", endDrag);
  canvas.addEventListener("pointercancel", endDrag);

  // Keyboard steps apply at once. Animating them would only make a held key feel slow.
  canvas.addEventListener("keydown", (event) => {
    const moves: Record<string, number> = { ArrowRight: STEP, ArrowUp: STEP, ArrowLeft: -STEP, ArrowDown: -STEP };
    if (!(event.key in moves)) return;
    event.preventDefault();
    cancelAnimationFrame(frame);
    frame = 0;
    ownsMotion = false;
    value = target = snap(target + moves[event.key]);
    velocity = 0;
    commit(value);
    draw();
    updateText();
  });

  for (const preset of presets) {
    preset.addEventListener("click", () => settle(Number(preset.dataset.minutes), 0));
  }

  toggle.addEventListener("click", () => {
    toggle.setAttribute("aria-checked", String(toggle.getAttribute("aria-checked") !== "true"));
  });

  // The session belongs to the whole page: the heat demo can end it, and the nav shows it.
  let wasAwake = false;

  session.subscribe((state) => {
    clearInterval(countdown);
    endsAt = state.endsAt;
    selected = state.minutes;
    panel!.dataset.awake = String(state.isAwake);
    play!.setAttribute("aria-label", state.isAwake ? "Stop" : "Keep awake");
    status!.textContent = state.isAwake ? "Awake with the lid closed" : session.SENTENCES[state.reason ?? "user"];
    if (state.isAwake) {
      countdown = window.setInterval(() => {
        if (endsAt === null || isDragging || ownsMotion) return;
        value = target = Math.max(0, endsAt - Date.now()) / 60_000;
        draw();
        updateText();
      }, 1000);
      if (!isDragging && !ownsMotion) value = target = state.minutes;
    } else if (wasAwake) {
      value = target = snap(state.minutes);
    }
    wasAwake = state.isAwake;
    updatePresets();
    draw();
    updateText();
  });

  play.addEventListener("click", () => {
    if (session.get().isAwake) session.stop("user");
    else session.start(selected);
  });

  new ResizeObserver(([entry]) => {
    width = entry.contentRect.width;
    draw();
  }).observe(canvas);
  width = canvas.clientWidth;
  draw();
  updateText();
}
