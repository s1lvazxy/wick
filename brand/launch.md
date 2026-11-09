# Launch copy

Words for telling people about Wick, in its own voice. Nothing here has been posted anywhere. Every number comes from the README, so if the app changes, change it there first and then here.

## The name, at three lengths

**Six words:** Close the lid. The agents stay late.

**One sentence:** Wick keeps a Mac or Linux laptop awake with the lid closed, so coding agents and builds finish while you walk away, and it always puts sleep back.

**One paragraph:** Your laptop thinks a closed lid means bedtime. Your coding agent was mid-sentence. Wick is a free, open source menu bar app and CLI that keeps a Mac or Linux laptop awake with the lid shut, for as long as you say, or until your agents finish. A separate guard process ends every session on time even if the app crashes. It lets go at 20% battery, and if the laptop runs hot with the lid closed for a minute, it stops, and there's no switch for that.

## Facts worth repeating

- Free, MIT licensed, no account, and it makes no network requests.
- macOS 14 or later on Apple silicon and Intel. Linux with systemd-logind.
- The Mac app is native Swift with no dependencies, about 5 MB.
- It knows 11 coding agents by name, Claude Code, Codex, Aider, OpenCode and Gemini CLI among them, and can stop 90 seconds after the last one exits.
- On a Mac the permission is one sudoers line that allows two exact `pmset` commands. On Linux it needs no root at all.
- Heat: hot with the lid closed for 60 seconds ends the session (macOS reports a serious thermal state, or the battery is at 45°C). Critical ends it at once.
- Not notarised yet, because there's no Apple Developer ID behind it. Homebrew handles that. A direct download needs Open Anyway the first time. Say so before anyone asks.

## Show HN

**Title:** Show HN: Wick – keep a laptop awake with the lid closed, and get sleep back afterwards

**Text:**

I kept closing my laptop on coding agents that were half way through something. `caffeinate` doesn't help, because closing the lid still sleeps the Mac. The setting that survives the lid is `pmset disablesleep 1`, and the trouble with that one is forgetting to turn it off.

So Wick is mostly about the turning off. Every session is enforced by a separate guard process, so the timer still ends if the app crashes or the terminal closes. It stops at a battery level you choose. It stops if the laptop runs hot with the lid closed for a minute, and you can't disable that. If the guard itself is killed, a launchd job picks the session up within five minutes.

It's a native menu bar app and a CLI on macOS, and a GNOME extension, tray app and CLI on Linux, where it holds a logind lid-switch inhibitor and needs no root. `wick run claude` keeps the laptop awake for exactly as long as one command runs. `wick on --agents` stops when the last coding agent exits.

Things I'd like to be told I got wrong: the sudoers rule on macOS (one line, two exact commands, but any process running as you can then flip the setting), and the Linux thermal thresholds, which are tuned on less hardware than I'd like.

Free and MIT. The site is the demo: https://s1lvazxy.github.io/wick/

## Reddit (r/macapps, r/commandline, r/ClaudeAI)

**Title:** I made a small menu bar app that keeps a MacBook awake with the lid closed, for running coding agents

**Text:**

Closing the lid sleeps a Mac even under `caffeinate`, which is annoying when an agent is half way through a job. Wick keeps it awake for a set time, or until your agents finish, and then puts sleep back.

The part I spent the time on is the stopping: a guard process that outlives the app, a battery floor, and a heat rule you can't turn off (hot with the lid closed for a minute, and it lets the Mac sleep). Still: don't put it in a bag while it's awake. Wick can end a session. It can't air-condition a backpack.

Free, open source, about 5 MB, no account and no network. Also runs on Linux.

`brew install --cask s1lvazxy/tap/wick`

https://s1lvazxy.github.io/wick/

## A thread

1. Your laptop thinks a closed lid means bedtime. Your coding agent was mid-sentence. I made Wick to settle that. Free and open source, for macOS and Linux.

2. `caffeinate` won't do it. Closing the lid still sleeps the Mac. The setting that survives is `pmset disablesleep 1`, and everyone who has used it has forgotten to turn it off at least once.

3. So Wick is mostly about turning it off. A guard process outlives the app. Time's up, sleep comes back. 20% battery, sleep comes back. Quit, log out, shut down: sleep comes back.

4. And it will not cook your laptop. Hot with the lid closed for a minute, and the session ends. There's no setting for that. That's the feature.

5. `wick run claude` keeps it awake for exactly as long as that command runs. `wick on --agents` stops when the last agent clocks out.

6. The website is a laptop you can close. Scroll, or drag the lid. https://s1lvazxy.github.io/wick/

## Product Hunt

**Tagline (60 characters):** Close the lid. Your coding agents keep working.

**Description (260 characters):** Wick keeps a Mac or Linux laptop awake with the lid closed, for a set time or until your agents finish, then puts sleep back. A guard outlives the app, it stops at low battery, and it won't cook your laptop. Free and open source.

## Images

| For | File |
| --- | --- |
| Link previews | `social/og.png` |
| The repository's social preview | `social/github.png` |
| Profile pictures | `social/avatar.png` |
| Anything else | The six laptops in `imagery/`, on Night or on Paper |

## Before posting

- Run `scripts/lid-test.sh` on a real Mac with the lid actually closed, and say in the post which machines it has been checked on.
- Check the install command on a clean machine, on the version the post links to.
- Thank [gust330](https://github.com/gust330), who started the Linux port.
