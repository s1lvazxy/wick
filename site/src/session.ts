// This page runs a Wick session of its own. The nav, the panel, the laptop and the heat demo all read it,
// so stopping it in one place stops it everywhere, the way the real app and CLI share one session file.

export type EndReason = "user" | "time" | "hot" | "critical";

export type Session = {
  isAwake: boolean;
  /** Milliseconds since the epoch, while awake. */
  endsAt: number | null;
  minutes: number;
  reason: EndReason | null;
};

/** The same sentences the app shows when a session ends. */
export const SENTENCES: Record<EndReason, string> = {
  user: "Sleeps when the lid closes",
  time: "Time's up. Sleep is back to normal.",
  hot: "Stopped to let the Mac cool down.",
  critical: "Stopped to let the Mac cool down.",
};

const listeners = new Set<(session: Session) => void>();
let current: Session = { isAwake: true, endsAt: Date.now() + 120 * 60_000, minutes: 120, reason: null };
let expiry = 0;

function publish(next: Session) {
  current = next;
  clearTimeout(expiry);
  if (next.isAwake && next.endsAt !== null) {
    // setTimeout tops out near 24 days, far past the panel's 12 hour ruler.
    expiry = window.setTimeout(() => stop("time"), Math.max(0, next.endsAt - Date.now()));
  }
  for (const listener of listeners) listener(current);
}

export function start(minutes = current.minutes) {
  publish({ isAwake: true, endsAt: Date.now() + minutes * 60_000, minutes, reason: null });
}

export function stop(reason: EndReason) {
  if (!current.isAwake) return;
  publish({ ...current, isAwake: false, endsAt: null, reason });
}

/** Changing the duration while awake restarts the countdown from the new length, as the app does. */
export function setMinutes(minutes: number) {
  publish({ ...current, minutes, endsAt: current.isAwake ? Date.now() + minutes * 60_000 : null });
}

export function get() {
  return current;
}

export function subscribe(listener: (session: Session) => void) {
  listeners.add(listener);
  listener(current);
}

export function clock(milliseconds: number) {
  const seconds = Math.max(0, Math.ceil(milliseconds / 1000));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/** `2h 05m`, `42m` or `<1m`, as the menu bar shows it. */
export function compact(milliseconds: number) {
  if (milliseconds < 60_000) return "<1m";
  const minutes = Math.ceil(milliseconds / 60_000);
  return minutes >= 60 ? `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m` : `${minutes}m`;
}
