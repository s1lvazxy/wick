// What's on the laptop's screen: an agent working through a fourteen-step job. The page's scroll position
// decides how far along it is, so by the time the lid opens again at dawn, it has finished.

const STEPS = [
  "Read the schema",
  "Planned the migration",
  "Wrote invoices_v2",
  "Backfilled 1.2M rows",
  "Rewrote the billing queries",
  "Fixed the test it broke",
  "Fixed the test that broke",
  "Ran the suite. 214 green",
  "Updated the docs",
  "Reran the flaky one",
  "Built the image",
  "Pushed the branch",
  "Opened the pull request",
  "Wrote you a summary",
];

export const STEP_COUNT = STEPS.length;

const WIDTH = 1280;
const HEIGHT = 860;
const MONO = '"Geist Mono Variable", ui-monospace, Menlo, monospace';

export function createScreen() {
  const canvas = document.createElement("canvas");
  canvas.width = WIDTH;
  canvas.height = HEIGHT;
  const g = canvas.getContext("2d")!;
  let drawnStep = -1;
  let drawnBlink = false;

  /** `progress` counts finished steps: 3.4 means three done and the fourth under way. Returns whether it redrew. */
  function draw(progress: number, seconds: number, force = false) {
    const done = Math.min(Math.floor(progress), STEP_COUNT);
    const blink = Math.floor(seconds * 2) % 2 === 0;
    if (!force && done === drawnStep && blink === drawnBlink) return false;
    drawnStep = done;
    drawnBlink = blink;

    g.fillStyle = "#0c0a09";
    g.fillRect(0, 0, WIDTH, HEIGHT);
    const glow = g.createRadialGradient(WIDTH / 2, HEIGHT * 1.25, 0, WIDTH / 2, HEIGHT * 1.25, HEIGHT * 0.9);
    glow.addColorStop(0, "rgb(217 66 26 / 34%)");
    glow.addColorStop(1, "rgb(217 66 26 / 0%)");
    g.fillStyle = glow;
    g.fillRect(0, 0, WIDTH, HEIGHT);

    // Title bar.
    g.fillStyle = "rgb(245 242 238 / 16%)";
    for (const x of [44, 78, 112]) {
      g.beginPath();
      g.arc(x, 46, 10, 0, Math.PI * 2);
      g.fill();
    }
    g.font = `500 24px ${MONO}`;
    g.textAlign = "center";
    g.fillStyle = "rgb(245 242 238 / 42%)";
    g.fillText("claude · ~/billing", WIDTH / 2, 54);
    g.textAlign = "left";

    const left = 64;
    let y = 150;
    const line = 54;
    g.font = `400 30px ${MONO}`;

    g.fillStyle = "rgb(245 242 238 / 46%)";
    g.fillText("$", left, y);
    g.fillStyle = "#f5f2ee";
    g.fillText("wick run claude", left + 38, y);
    y += line;
    g.fillStyle = "rgb(245 242 238 / 46%)";
    g.fillText("Awake while this runs. Back to normal when it exits.", left, y);
    y += line * 1.5;

    g.fillStyle = "#f5f2ee";
    g.fillText("Migrating billing to the new schema", left, y);
    g.fillStyle = "rgb(245 242 238 / 46%)";
    g.textAlign = "right";
    g.fillText(`${Math.min(done + 1, STEP_COUNT)} of ${STEP_COUNT}`, WIDTH - left, y);
    g.textAlign = "left";
    y += line * 0.6;

    // The progress bar is the same ruler as the app's: lit ticks are what's done.
    for (let tick = 0; tick < 56; tick++) {
      const lit = tick / 56 < done / STEP_COUNT;
      g.fillStyle = lit ? "#ffc27a" : "rgb(245 242 238 / 16%)";
      g.fillRect(left + tick * ((WIDTH - 2 * left) / 56), y, 3, tick % 4 === 0 ? 30 : 18);
    }
    y += line * 1.7;

    const finished = done >= STEP_COUNT;
    const first = Math.max(0, Math.min(done - 4, STEP_COUNT - 6));
    for (let index = first; index < Math.min(first + 6, STEP_COUNT); index++) {
      const isDone = index < done;
      const isCurrent = index === done;
      if (!isDone && !isCurrent) break;
      if (isCurrent) {
        g.fillStyle = "#ff8a3d";
        g.beginPath();
        g.arc(left + 10, y - 10, 9, 0, Math.PI * 2);
        g.fill();
      } else {
        g.fillStyle = "rgb(245 242 238 / 46%)";
        g.fillText("✓", left, y);
      }
      g.fillStyle = isCurrent ? "#f5f2ee" : "rgb(245 242 238 / 62%)";
      g.fillText(`${String(index + 1).padStart(2, " ")}  ${STEPS[index]}`, left + 44, y);
      if (isCurrent && blink) {
        const width = g.measureText(`${String(index + 1).padStart(2, " ")}  ${STEPS[index]} `).width;
        g.fillStyle = "#ff8a3d";
        g.fillRect(left + 44 + width, y - 26, 16, 32);
      }
      y += line;
    }

    if (finished) {
      y += line * 0.4;
      g.fillStyle = "#ffc27a";
      g.fillText("Done at 06:12. Sleep is back to normal.", left, y);
    }
    return true;
  }

  return { canvas, draw };
}
