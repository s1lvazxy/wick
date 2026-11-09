import "lenis/dist/lenis.css";
import "./style.css";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { SplitText } from "gsap/SplitText";
import Lenis from "lenis";
import { mountDemo } from "./demo";
import { mountHeat } from "./heat";
import { createScreen, STEP_COUNT } from "./screen";
import * as session from "./session";
import type { Pose, World } from "./world";

gsap.registerPlugin(ScrollTrigger, SplitText);

const root = document.documentElement;
/** Reduced motion: the page becomes plain flow with stills, and nothing is tied to scroll. */
const isStill = matchMedia("(prefers-reduced-motion: reduce)").matches;

function $<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (!element) throw new Error(`Missing ${selector}`);
  return element;
}

const mix = (a: number, b: number, t: number) => a + (b - a) * t;
const smooth = (t: number) => t * t * (3 - 2 * t);

const nav = $<HTMLElement>(".nav");
const scene = $<HTMLElement>(".scene");
const stage = $<HTMLElement>(".stage");
const heat = $<HTMLElement>(".heat");
const heatSlot = $<HTMLElement>("#heat-slot");
const dawn = $<HTMLElement>(".dawn");
const dawnSlot = $<HTMLElement>("#dawn-slot");
const canvas = $<HTMLCanvasElement>("#world");

// MARK: Smooth scroll

let lenis: Lenis | null = null;
if (!isStill) {
  lenis = new Lenis({ anchors: true });
  lenis.on("scroll", ScrollTrigger.update);
  gsap.ticker.add((time) => lenis?.raf(time * 1000));
  gsap.ticker.lagSmoothing(0);
}

// MARK: The first scene, where the lid closes

let sceneProgress = 0;
let dawnProgress = 0;

if (!isStill) {
  const closing = gsap.timeline({
    defaults: { ease: "none" },
    scrollTrigger: {
      trigger: scene,
      start: "top top",
      end: "bottom bottom",
      scrub: true,
      onUpdate: (self) => {
        sceneProgress = self.progress;
        scene.dataset.tone = self.progress > 0.33 ? "night" : "day";
      },
    },
  });

  closing
    .to(".cue", { autoAlpha: 0, duration: 0.03 }, 0.005)
    .to(".lede, .hero-actions", { autoAlpha: 0, y: -16, duration: 0.06 }, 0.02)
    .to(".hero h1 .line > span", { yPercent: -108, duration: 0.07, stagger: 0.014, ease: "power1.in" }, 0.045)
    .set(".hero", { visibility: "hidden" }, 0.15)
    .to(".sky-dusk", { opacity: 1, duration: 0.2 }, 0.1)
    .to(".sky-night", { opacity: 1, duration: 0.22 }, 0.28);

  const says: [string, number, number][] = [
    // They share one spot on the page, so each has left before the next arrives.
    ['.say[data-who="macos"]', 0.12, 0.2],
    ['.say[data-who="agent"]', 0.235, 0.305],
    ['.say[data-who="wick"]', 0.34, 0.5],
    [".aside", 0.415, 0.5],
  ];
  for (const [selector, enter, leave] of says) {
    closing
      .fromTo(selector, { autoAlpha: 0, y: 18 }, { autoAlpha: 1, y: 0, duration: 0.03, ease: "power2.out" }, enter)
      .to(selector, { autoAlpha: 0, y: -12, duration: 0.03, ease: "power1.in" }, leave);
  }

  closing
    .fromTo(".closed", { autoAlpha: 0, y: 28 }, { autoAlpha: 1, y: 0, duration: 0.1, ease: "power2.out" }, 0.62)
    .set({}, {}, 1);

  gsap
    .timeline({
      defaults: { ease: "none" },
      scrollTrigger: {
        trigger: dawn,
        start: "top top",
        end: "bottom bottom",
        scrub: true,
        onUpdate: (self) => {
          dawnProgress = self.progress;
          dawn.dataset.tone = self.progress > 0.4 ? "day" : "night";
        },
      },
    })
    .to(".sky-dawn", { yPercent: -75, duration: 0.62 }, 0.04)
    .fromTo(".dawn-copy", { autoAlpha: 0, y: 24 }, { autoAlpha: 1, y: 0, duration: 0.16, ease: "power2.out" }, 0.46)
    .set({}, {}, 1);

  // The safety list's line burns down like a wick as you read.
  const rail = $<HTMLElement>(".rail-line");
  const railFill = $<HTMLElement>(".rail-fill");
  const railEmber = $<HTMLElement>(".rail-ember");
  ScrollTrigger.create({
    trigger: rail,
    start: "top 72%",
    end: "bottom 72%",
    scrub: true,
    onUpdate: (self) => {
      railFill.style.transform = `scaleY(${self.progress})`;
      railEmber.style.transform = `translateY(${self.progress * rail.offsetHeight}px)`;
    },
  });
}

// MARK: Things that arrive as you reach them

if (!isStill) {
  // Section titles come up a line at a time, from behind their own baseline.
  for (const title of document.querySelectorAll<HTMLElement>("h2.split")) {
    SplitText.create(title, {
      type: "lines",
      mask: "lines",
      autoSplit: true,
      onSplit: (split) =>
        gsap.from(split.lines, {
          yPercent: 108,
          duration: 0.9,
          stagger: 0.08,
          ease: "expo.out",
          scrollTrigger: { trigger: title, start: "top 88%", once: true },
        }),
    });
  }
}

const reveals = [...document.querySelectorAll<HTMLElement>(".reveal")];
if (isStill || !("IntersectionObserver" in window)) {
  for (const element of reveals) element.classList.add("in");
} else {
  const observer = new IntersectionObserver(
    (entries) => {
      // Elements that arrive together are staggered, so the eye gets an order to read them in.
      let order = 0;
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        (entry.target as HTMLElement).style.transitionDelay = `${order++ * 70}ms`;
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -12% 0px" },
  );
  for (const element of reveals) observer.observe(element);
}

// MARK: The laptop's poses

/** A pose placed inside an element: `ox` and `oy` are fractions of that element, `fit` is the laptop's share of its width. */
function placed(element: HTMLElement, pose: Omit<Pose, "x" | "y" | "size" | "alpha">, fit: number, ox = 0, oy = 0): Pose {
  const box = element.getBoundingClientRect();
  const width = innerWidth;
  const height = innerHeight;
  return {
    ...pose,
    x: (box.left + box.width * (0.5 + ox) - width / 2) / width,
    y: (box.top + box.height * (0.5 + oy) - height / 2) / height,
    // On a short, wide window the width alone would let the laptop outgrow the height.
    size: Math.min(box.width * fit, box.height * fit * 1.9) / width,
    alpha: 1,
  };
}

const isWide = () => innerWidth >= 880 && innerWidth > innerHeight * 0.9;
const lidInHeat = { angle: 0 };

const poses = {
  hero: () =>
    isWide()
      ? placed(stage, { lid: 104, az: -30, el: 13, light: 1, ember: 0 }, 0.37, 0.235, 0.14)
      : placed(stage, { lid: 104, az: -22, el: 13, light: 1, ember: 0 }, 0.74, 0, 0.19),
  // Part way round. Seen from a corner the laptop is at its widest, so it's held smaller until it's side on.
  turn: () =>
    isWide()
      ? placed(stage, { lid: 64, az: -66, el: 5, light: 0.62, ember: 1 }, 0.46, 0.06, 0.07)
      : placed(stage, { lid: 64, az: -66, el: 5, light: 0.62, ember: 1 }, 0.74, 0, 0.1),
  // The side view, lid at 35 degrees, is the logo.
  logo: () =>
    isWide()
      ? placed(stage, { lid: 35, az: -90, el: 0, light: 0.3, ember: 1 }, 0.62, 0, 0.05)
      : placed(stage, { lid: 35, az: -90, el: 0, light: 0.3, ember: 1 }, 1.16, 0, 0.06),
  shut: () =>
    isWide()
      ? placed(stage, { lid: 0, az: -90, el: 0, light: 0.1, ember: 1 }, 0.62, 0, 0.09)
      : placed(stage, { lid: 0, az: -90, el: 0, light: 0.1, ember: 1 }, 1.16, 0, 0.1),
  rest: () =>
    isWide()
      ? placed(stage, { lid: 0, az: -34, el: 17, light: 0.12, ember: 1 }, 0.42, 0, 0.27)
      : placed(stage, { lid: 0, az: -30, el: 20, light: 0.12, ember: 1 }, 0.8, 0, 0.27),
  heat: () => {
    const open = lidInHeat.angle / 100;
    return placed(heatSlot, { lid: lidInHeat.angle, az: -32, el: mix(30, 16, open), light: 0.14, ember: 1 }, mix(0.84, 0.66, open), 0, mix(0.04, 0.1, open));
  },
  dusk: () => placed(dawnSlot, { lid: 0, az: -26, el: 15, light: 0.12, ember: 1 }, 0.9, 0, 0.12),
  // The lid has only just lifted, and the ember has already become the sunrise.
  stir: () => placed(dawnSlot, { lid: 24, az: -24, el: 14, light: 0.4, ember: 0 }, 0.9, 0, 0.12),
  morning: () => placed(dawnSlot, { lid: 104, az: -18, el: 11, light: 1, ember: 0 }, isWide() ? 0.66 : 0.9, 0, 0.16),
};

type Key = { at: number; pose: () => Pose; visible: boolean };
let keys: Key[] = [];
let jobMarks: [number, number][] = [];

function measure() {
  const viewport = innerHeight;
  const top = (element: HTMLElement) => element.getBoundingClientRect().top + scrollY;
  const sceneTop = top(scene);
  const sceneLength = scene.offsetHeight - viewport;
  const at = (progress: number) => sceneTop + progress * sceneLength;
  const heatTop = top(heat);
  const heatBottom = heatTop + heat.offsetHeight;
  const dawnTop = top(dawn);
  const dawnLength = dawn.offsetHeight - viewport;

  const key = (position: number, pose: () => Pose, visible = true): Key => ({ at: position, pose, visible });
  keys = [
    key(at(0), poses.hero),
    key(at(0.04), poses.hero),
    key(at(0.27), poses.turn),
    key(at(0.42), poses.logo),
    key(at(0.5), poses.logo),
    key(at(0.6), poses.shut),
    key(at(0.8), poses.rest),
    // Past here the stage is no longer pinned, and a pose placed inside it scrolls away with it.
    key(at(1) + viewport, poses.rest),
    key(at(1) + viewport + 1, poses.rest, false),
    key(heatTop - viewport, poses.heat, false),
    key(heatTop - viewport * 0.55, poses.heat),
    key(heatBottom - viewport * 0.55, poses.heat),
    key(heatBottom - viewport * 0.2, poses.heat, false),
    key(dawnTop - viewport, poses.dusk, false),
    key(dawnTop - viewport * 0.7, poses.dusk),
    key(dawnTop + dawnLength * 0.1, poses.dusk),
    key(dawnTop + dawnLength * 0.26, poses.stir),
    key(dawnTop + dawnLength * 0.62, poses.morning),
    key(dawnTop + dawnLength + viewport, poses.morning),
    key(dawnTop + dawnLength + viewport + 1, poses.morning, false),
  ];

  // How far the agent's job has got, by scroll position. It's on step 9 when the lid shuts and done by dawn.
  jobMarks = [
    [at(0), 3.4],
    [at(0.3), 8.6],
    [at(1), 9.5],
    [dawnTop, 13.4],
    [dawnTop + dawnLength * 0.45, STEP_COUNT],
  ];
}

function between<T>(marks: T[], position: (mark: T) => number, value: number): [T, T, number] {
  if (value <= position(marks[0])) return [marks[0], marks[0], 0];
  for (let index = 1; index < marks.length; index++) {
    const start = position(marks[index - 1]);
    const end = position(marks[index]);
    if (value <= end) return [marks[index - 1], marks[index], (value - start) / Math.max(end - start, 1)];
  }
  const last = marks[marks.length - 1];
  return [last, last, 0];
}

const FIELDS = ["lid", "az", "el", "size", "x", "y", "light", "ember"] as const;

function poseAt(scroll: number): Pose {
  const [from, to, raw] = between(keys, (key) => key.at, scroll);
  const a = from.pose();
  const b = from === to ? a : to.pose();
  const t = smooth(raw);
  const pose = { ...a };
  for (const field of FIELDS) pose[field] = mix(a[field], b[field], t);
  pose.alpha = mix(from.visible ? 1 : 0, to.visible ? 1 : 0, raw);
  return pose;
}

function jobAt(scroll: number) {
  const [from, to, t] = between(jobMarks, (mark) => mark[0], scroll);
  return mix(from[1], to[1], t);
}

// MARK: The page's own session, in the nav

const hud = $<HTMLElement>(".hud");
const hudTime = $<HTMLElement>("#hud-time");
const hudNote = $<HTMLElement>("#hud-note");
const barTime = document.querySelector<HTMLElement>("#bar-time");
let lidIsClosed = false;
let jobStep = 4;

function updateHud() {
  const state = session.get();
  if (state.isAwake && state.endsAt !== null) {
    const left = state.endsAt - Date.now();
    hudTime.textContent = session.clock(left);
    hudNote.textContent = `lid ${lidIsClosed ? "closed" : "open"} · step ${jobStep}/${STEP_COUNT}`;
    hud.dataset.state = lidIsClosed ? "closed" : "open";
    if (barTime) barTime.textContent = session.compact(left);
  } else {
    hudTime.textContent = "Asleep";
    hudNote.textContent = state.reason === "hot" || state.reason === "critical" ? "it got too hot" : "sleeping normally";
    hud.dataset.state = "off";
    if (barTime) barTime.textContent = "";
  }
  root.dataset.awake = String(state.isAwake);
}

session.subscribe(updateHud);
setInterval(updateHud, 1000);

// MARK: One frame

const screen = createScreen();
let world: World | null = null;
const intro = { open: 0, alpha: 0 };
const toneSections = [...document.querySelectorAll<HTMLElement>("main > [data-tone], main > .scene, main > .dawn, .footer")];
let lastTone = "";

function updateTone() {
  const under = toneSections.find((section) => {
    const box = section.getBoundingClientRect();
    return box.top <= 36 && box.bottom > 36;
  });
  let tone = under?.dataset.tone ?? "day";
  // With reduced motion the first scene is two plain blocks, a day one and then a night one.
  if (isStill && under === scene) tone = $<HTMLElement>(".closed").getBoundingClientRect().top <= 36 ? "night" : "day";
  if (isStill && under === dawn) tone = "day";
  if (tone !== lastTone) {
    lastTone = tone;
    nav.dataset.tone = tone;
  }
  // These two carry their own sky, and a band of either colour would show against it.
  const isClear = String(!isStill && (under === scene || under === dawn));
  if (nav.dataset.clear !== isClear) nav.dataset.clear = isClear;
}

// The laptop leans a little towards the pointer. Decoration, so it's sprung, and it's off for the side view
// that has to stay exactly the logo.
const pointer = { x: 0, y: 0, leanX: 0, leanY: 0 };
if (!isStill && matchMedia("(hover: hover) and (pointer: fine)").matches) {
  addEventListener(
    "pointermove",
    (event) => {
      pointer.x = (event.clientX / innerWidth) * 2 - 1;
      pointer.y = (event.clientY / innerHeight) * 2 - 1;
    },
    { passive: true },
  );
}
let lastSeconds = 0;

function frame(seconds: number) {
  const scroll = lenis ? lenis.scroll : scrollY;
  const elapsed = Math.min(seconds - lastSeconds, 0.1);
  lastSeconds = seconds;
  updateTone();

  const step = Math.min(Math.floor(jobAt(scroll)) + 1, STEP_COUNT);
  const closed = sceneProgress >= 0.58 && dawnProgress < 0.3;
  // Once the lid is most of the way down there's no lid left to grab.
  const canGrab = sceneProgress < 0.5 && scroll < scene.offsetTop + scene.offsetHeight - innerHeight;
  if (grab.hidden === canGrab) grab.hidden = !canGrab;
  if (step !== jobStep || closed !== lidIsClosed) {
    jobStep = step;
    lidIsClosed = closed;
    updateHud();
  }

  if (!world) return;
  const pose = poseAt(scroll);
  const ease = 1 - Math.exp(-elapsed * 5);
  pointer.leanX += (pointer.x - pointer.leanX) * ease;
  pointer.leanY += (pointer.y - pointer.leanY) * ease;
  const freedom = smooth(Math.min(Math.abs(pose.az + 90) / 40, 1));
  pose.az += pointer.leanX * 4 * freedom;
  pose.el -= pointer.leanY * 2.2 * freedom;
  pose.lid *= intro.open;
  pose.alpha *= intro.alpha;
  canvas.style.opacity = String(pose.alpha);
  if (pose.alpha > 0.001 && pose.lid > 8 && screen.draw(jobAt(scroll), seconds)) world.screenChanged();
  world.render(pose, seconds);
}

async function boot() {
  measure();
  mountDemo();
  mountHeat((value, lidOpen) => {
    world?.setHeat(value);
    const angle = lidOpen ? 100 : 0;
    if (isStill) lidInHeat.angle = angle;
    else gsap.to(lidInHeat, { angle, duration: 0.7, ease: "power3.out", overwrite: true });
  });

  const wantsCapture = import.meta.env.DEV && new URLSearchParams(location.search).has("capture");
  if (isStill && !wantsCapture) {
    root.classList.add("flat");
    updateTone();
    addEventListener("scroll", updateTone, { passive: true });
    return;
  }

  try {
    const [{ createWorld }] = await Promise.all([
      import("./world"),
      document.fonts.load('30px "Geist Mono Variable"').catch(() => undefined),
    ]);
    screen.draw(jobAt(scrollY), 0, true);
    world = createWorld(canvas, screen.canvas, !isStill);
  } catch {
    world = null;
  }
  if (!world) {
    root.classList.add("flat");
    gsap.ticker.add(frame);
    return;
  }

  root.classList.add("live");
  session.subscribe((state) => world?.setAwake(state.isAwake));
  ScrollTrigger.addEventListener("refresh", measure);
  addEventListener("resize", () => {
    world?.resize();
    measure();
  });
  gsap.ticker.add(frame);
  // Opening the page opens the laptop.
  gsap.to(intro, { alpha: 1, duration: 0.5, ease: "power1.out" });
  gsap.to(intro, { open: 1, duration: 1.6, ease: "expo.out", delay: 0.15 });

  if (wantsCapture) {
    const live = world;
    Object.assign(window, {
      wickCapture: (name: keyof typeof poses, width: number, height: number, overrides: Partial<Pose> = {}, heatLevel = 0) => {
        const centred = { ...poses[name](), x: 0, y: 0, alpha: 1, ...overrides };
        screen.draw(name === "morning" ? STEP_COUNT : 3.4, 0, true);
        live.screenChanged();
        live.setHeat(heatLevel);
        const still = live.capture(centred, width, height);
        live.setHeat(0);
        return still;
      },
    });
  }
}

// MARK: Dragging the lid shut

// The lid is tied to scroll, so dragging it is scrolling by hand: one position, two ways to move it.
const grab = $<HTMLElement>(".lid-grab");
if (!isStill) {
  let startY = 0;
  let startScroll = 0;
  let isDragging = false;
  grab.addEventListener("pointerdown", (event) => {
    if (event.pointerType !== "mouse" || event.button !== 0) return;
    grab.setPointerCapture(event.pointerId);
    isDragging = true;
    startY = event.clientY;
    startScroll = lenis ? lenis.scroll : scrollY;
    grab.dataset.dragging = "true";
    event.preventDefault();
  });
  grab.addEventListener("pointermove", (event) => {
    if (!isDragging) return;
    const limit = scene.offsetTop + (scene.offsetHeight - innerHeight) * 0.66;
    const target = Math.min(Math.max(startScroll + (event.clientY - startY) * 4.4, 0), limit);
    if (lenis) lenis.scrollTo(target, { immediate: true, force: true });
    else scrollTo(0, target);
  });
  const release = () => {
    isDragging = false;
    grab.dataset.dragging = "false";
  };
  grab.addEventListener("pointerup", release);
  grab.addEventListener("pointercancel", release);
}

// MARK: Copy buttons

const copyStatus = $<HTMLElement>("#copy-status");

for (const button of document.querySelectorAll<HTMLButtonElement>("[data-copy]")) {
  let reset = 0;
  button.addEventListener("click", async () => {
    const text = button.dataset.copy ?? "";
    clearTimeout(reset);
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
      copyStatus.textContent = `Copied: ${text}`;
    } catch {
      // No clipboard access (an insecure origin, or a refused permission): select it, so ⌘C is one key away.
      const code = button.parentElement?.querySelector("code");
      if (code) getSelection()?.selectAllChildren(code);
      button.textContent = "Press ⌘C";
      copyStatus.textContent = "Couldn't copy. The command is selected, press Command C.";
    }
    reset = window.setTimeout(() => {
      button.textContent = "Copy";
    }, 1600);
  });
}

// MARK: Install tabs

const tabs = [...document.querySelectorAll<HTMLButtonElement>('[role="tab"]')];

function selectTab(selected: HTMLButtonElement, moveFocus: boolean) {
  for (const tab of tabs) {
    const isSelected = tab === selected;
    tab.setAttribute("aria-selected", String(isSelected));
    tab.tabIndex = isSelected ? 0 : -1;
    $<HTMLElement>(`#${tab.getAttribute("aria-controls")}`).hidden = !isSelected;
  }
  if (moveFocus) selected.focus();
  // The panels differ in height, and everything below is measured from the top of the page.
  ScrollTrigger.refresh();
}

tabs.forEach((tab, index) => {
  tab.addEventListener("click", () => selectTab(tab, false));
  tab.addEventListener("keydown", (event) => {
    const moves: Record<string, number> = {
      ArrowRight: index + 1,
      ArrowLeft: index - 1 + tabs.length,
      Home: 0,
      End: tabs.length - 1,
    };
    if (!(event.key in moves)) return;
    event.preventDefault();
    selectTab(tabs[moves[event.key] % tabs.length], true);
  });
});

for (const details of document.querySelectorAll("details")) {
  details.addEventListener("toggle", () => ScrollTrigger.refresh());
}

document.fonts?.ready.then(() => ScrollTrigger.refresh());
boot();
