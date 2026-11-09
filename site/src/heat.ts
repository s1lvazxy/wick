// A playable copy of Wick's heat rule. The thresholds are the app's: hot with the lid closed for a minute
// ends the session, and critical ends it at once. Only the clock is faster, so nobody has to stand here for 60s.

import * as session from "./session";

const HOT = 14 / 31; // 45°C on a scale that runs from 31°C to 62°C.
const WARM = 0.2;
const CRITICAL = 0.9;
const MINUTE = 5; // Real seconds that stand in for the app's sixty.

type Level = "cool" | "warm" | "hot" | "critical";

const NAMES: Record<Level, string> = { cool: "Cool", warm: "Warm", hot: "Hot", critical: "Critical" };

function levelOf(heat: number): Level {
  if (heat >= CRITICAL) return "critical";
  if (heat >= HOT) return "hot";
  if (heat >= WARM) return "warm";
  return "cool";
}

export function mountHeat(onChange: (heat: number, lidOpen: boolean) => void) {
  const hold = document.querySelector<HTMLButtonElement>("#heat-hold");
  const label = hold?.querySelector<HTMLElement>(".hold-label");
  const gauge = document.querySelector<HTMLElement>("#gauge");
  const temperature = document.querySelector<HTMLElement>("#heat-temp");
  const levelText = document.querySelector<HTMLElement>("#heat-level");
  const fill = document.querySelector<HTMLElement>("#heat-fill");
  const log = document.querySelector<HTMLElement>("#heat-log");
  const status = document.querySelector<HTMLElement>("#heat-status");
  const timer = document.querySelector<HTMLElement>("#heat-timer");
  const small = document.querySelector<HTMLElement>("#heat-small");
  const steam = document.querySelector<SVGElement>(".steam");
  const panelHeat = document.querySelector<HTMLElement>("#demo-heat");
  const lidClosed = document.querySelector<HTMLButtonElement>("#lid-closed");
  const lidOpen = document.querySelector<HTMLButtonElement>("#lid-open");
  if (!hold || !label || !gauge || !temperature || !levelText || !fill || !log || !timer || !small || !lidClosed || !lidOpen) {
    return;
  }

  let heat = 0;
  let isHolding = false;
  let isLidOpen = false;
  let hotFor = 0;
  let frame = 0;
  let last = 0;
  let message = "";
  let wasHot = false;

  /** `aloud` is for changes of state. The running count isn't read out, or a screen reader would never stop. */
  function say(text: string, aloud = true) {
    if (text === message) return;
    message = text;
    log!.textContent = text;
    if (aloud && status) status.textContent = text;
  }

  function paint() {
    const level = levelOf(heat);
    const degrees = Math.round(31 + heat * 31);
    gauge!.dataset.level = level;
    temperature!.textContent = String(degrees);
    levelText!.textContent = NAMES[level];
    fill!.style.transform = `scaleX(${Math.max(heat, 0.012)})`;
    timer!.style.transform = `scaleX(${Math.min(hotFor / MINUTE, 1)})`;
    if (steam) steam.style.opacity = String(Math.min(Math.max((heat - 0.3) / 0.35, 0), 1));
    if (panelHeat) panelHeat.textContent = `${NAMES[level]}, battery ${degrees}°C`;
    onChange(heat, isLidOpen);
  }

  function step(now: number) {
    frame = 0;
    const elapsed = last ? Math.min((now - last) / 1000, 0.05) : 1 / 60;
    last = now;
    const isAwake = session.get().isAwake;

    // Heat climbs quickly to hot, then slowly, so there's time to watch the minute run.
    if (isHolding) heat = Math.min(1, heat + (heat < HOT ? 0.2 : 0.055) * elapsed);
    else heat = Math.max(0, heat - 0.28 * elapsed);

    const level = levelOf(heat);
    const isHot = level === "hot" || level === "critical";

    if (isAwake) {
      if (level === "critical") {
        hotFor = 0;
        session.stop("critical");
        say("Critical. Stopped at once, lid or no lid.");
      } else if (isHot && !isLidOpen) {
        hotFor += elapsed;
        const shown = Math.min(60, Math.floor((hotFor / MINUTE) * 60));
        if (hotFor === elapsed && status) status.textContent = "Hot with the lid closed. Wick stops if this lasts a minute.";
        say(`Hot with the lid closed. 0:${String(shown).padStart(2, "0")} of 1:00.`, false);
        if (hotFor >= MINUTE) {
          hotFor = 0;
          session.stop("hot");
          say(session.SENTENCES.hot);
        }
      } else if (isHot) {
        hotFor = 0;
        say("Hot, but the lid's open and the heat has somewhere to go. Wick lets it ride.");
      } else {
        if (wasHot && hotFor > 0) say("One cool reading. The minute starts over.");
        else if (!wasHot || level === "cool") {
          say(level === "warm" ? "Warming up. The fans are thinking about it." : `Awake, lid ${isLidOpen ? "open" : "closed"}, perfectly comfortable.`);
        }
        hotFor = 0;
      }
    }
    wasHot = isHot;

    paint();
    if (isHolding || heat > 0) frame = requestAnimationFrame(step);
    else last = 0;
  }

  function run() {
    if (!frame) frame = requestAnimationFrame(step);
  }

  function press() {
    if (!session.get().isAwake) {
      // Nothing left to protect, so the same button relights the session.
      session.start();
      return;
    }
    isHolding = true;
    hold!.dataset.holding = "true";
    run();
  }

  function release() {
    isHolding = false;
    hold!.dataset.holding = "false";
  }

  hold.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    hold.setPointerCapture(event.pointerId);
    press();
  });
  hold.addEventListener("pointerup", release);
  hold.addEventListener("pointercancel", release);
  hold.addEventListener("lostpointercapture", release);
  hold.addEventListener("contextmenu", (event) => event.preventDefault());
  hold.addEventListener("keydown", (event) => {
    if ((event.key === " " || event.key === "Enter") && !event.repeat) {
      event.preventDefault();
      press();
    }
  });
  hold.addEventListener("keyup", (event) => {
    if (event.key === " " || event.key === "Enter") release();
  });
  hold.addEventListener("blur", release);

  function setLid(open: boolean) {
    isLidOpen = open;
    lidClosed!.setAttribute("aria-pressed", String(!open));
    lidOpen!.setAttribute("aria-pressed", String(open));
    hotFor = 0;
    if (session.get().isAwake && heat < HOT) say(`Awake, lid ${open ? "open" : "closed"}, perfectly comfortable.`);
    paint();
  }
  lidClosed.addEventListener("click", () => setLid(false));
  lidOpen.addEventListener("click", () => setLid(true));

  session.subscribe((state) => {
    label!.textContent = state.isAwake ? "Hold to heat" : "Relight";
    hold!.dataset.asleep = String(!state.isAwake);
    if (state.isAwake) {
      small!.textContent = "The minute runs at 12× here. You have places to be.";
      if (heat < WARM) say(`Awake, lid ${isLidOpen ? "open" : "closed"}, perfectly comfortable.`);
    } else if (state.reason === "hot" || state.reason === "critical") {
      small!.textContent = "The laptop is asleep now, cooling down, slightly embarrassed.";
    } else {
      small!.textContent = "No session, nothing to protect. Relight it and try again.";
      say("Sleeping normally.");
    }
  });

  paint();
}
