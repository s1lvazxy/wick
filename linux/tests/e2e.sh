#!/bin/bash
# End-to-end test of the CLI and the guard against a simulated lock. Needs no root and no logind, and runs
# anywhere. tests/logind/ covers the real thing.
set -u
cd "$(dirname "$0")/.."

wick="$(realpath wick-dev)"

work=$(mktemp -d)
trap 'pkill -f "$wick guard" 2>/dev/null; rm -rf "$work"' EXIT
export WICK_STATE_DIR="$work/state" WICK_SIMULATE_POWER_FILE="$work/power"
echo 0 > "$WICK_SIMULATE_POWER_FILE"

failures=0
power() { cat "$WICK_SIMULATE_POWER_FILE"; }
guards() { pgrep -f "^[^ ]*python.* $wick guard" | wc -l | tr -d ' '; }
settled_guards() { # expected: waits out a spare guard's lock retries
    for _ in $(seq 1 80); do [ "$(guards)" = "$1" ] && break; sleep 0.1; done
    guards
}
expect() { # description expected actual
    if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1 (expected '$2', got '$3')"; failures=$((failures + 1)); fi
}
wait_for() { # expected-power seconds
    for _ in $(seq 1 $(($2 * 10))); do [ "$(power)" = "$1" ] && return 0; sleep 0.1; done
    return 1
}
last_reason() { sed -n 's/.*"reason": *"\([^"]*\)".*/\1/p' "$WICK_STATE_DIR/last-end.json" 2>/dev/null; }

echo "=== 1. on, off ==="
"$wick" on >/dev/null
expect "on turns sleep off" 1 "$(power)"
expect "one guard is running" 1 "$(settled_guards 1)"
"$wick" off >/dev/null
expect "off turns sleep on" 0 "$(power)"
sleep 7
expect "guard exits on its own once the session is gone" 0 "$(settled_guards 0)"

echo "=== 2. only one guard ==="
"$wick" on >/dev/null; "$wick" on 2h >/dev/null; "$wick" on 1h >/dev/null
expect "repeat starts share one guard" 1 "$(settled_guards 1)"
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2

echo "=== 3. timer ==="
"$wick" on 2s >/dev/null
expect "stays on before the deadline" 1 "$(power)"
wait_for 0 5; expect "sleep returns at the deadline, without the CLI running" 0 "$(power)"
expect "records why" timeUp "$(last_reason)"

echo "=== 4. crash safety ==="
"$wick" on >/dev/null
sleep 0.3
pkill -TERM -f "$wick guard"
wait_for 0 3; expect "SIGTERM on the guard (logout, shutdown) restores sleep" 0 "$(power)"

"$wick" on 2s >/dev/null
sleep 0.3
pkill -KILL -f "$wick guard"
sleep 3
expect "SIGKILL leaves the setting on until someone looks" 1 "$(power)"
"$wick" status >/dev/null
wait_for 0 3; expect "next launch restarts the guard, which ends the expired session" 0 "$(power)"

echo "=== 5. terminal closing ==="
(bash -c "\"$wick\" on 30m >/dev/null; kill -HUP \$\$" 2>/dev/null) 2>/dev/null
expect "guard survives the terminal" 1 "$(settled_guards 1)"
expect "still on" 1 "$(power)"
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2

echo "=== 6. external change ==="
"$wick" on 30m >/dev/null
echo 0 > "$WICK_SIMULATE_POWER_FILE"
sleep 7
expect "guard notices sleep turned back on elsewhere" stoppedExternally "$(last_reason)"
expect "and exits" 0 "$(settled_guards 0)"

echo "=== 7. wick run ==="
"$wick" run sh -c 'cat "$WICK_SIMULATE_POWER_FILE" > "$WICK_STATE_DIR/during"; exit 7'
code=$?
expect "on while the command runs" 1 "$(cat "$WICK_STATE_DIR/during")"
expect "off once it finishes" 0 "$(power)"
expect "passes the exit code through" 7 "$code"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

"$wick" run sh -c 'kill -9 $PPID; exec sleep 9' &
held=$!
sleep 7
expect "killing wick run ends the session through the guard" 0 "$(power)"
wait "$held" 2>/dev/null
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

"$wick" on 30m >/dev/null
"$wick" run true
expect "a run inside an open session leaves that session alone" 1 "$(power)"
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2

"$wick" on 2s >/dev/null
"$wick" run sleep 4 &
held=$!
sleep 3
expect "a running command outlives the timer" 1 "$(power)"
wait "$held"
wait_for 0 7; expect "and the timer applies once it exits" 0 "$(power)"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

"$wick" run sleep 2 &
held=$!
sleep 0.5
"$wick" on 8h >/dev/null
wait "$held"
expect "a command's exit doesn't end a session started after it" 1 "$(power)"
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2

echo "=== 8. wick run on a real terminal ==="
pty_runner="$(realpath tests/run_pty.py)"
on_pty() { perl -e 'alarm 10; exec @ARGV' "$pty_runner" "$wick" run "$@" 2>&1 | tr -d '\r'; }

output=$( (sleep 0.5; printf 'hello\n'; sleep 0.5) | on_pty sh -c 'stty size >/dev/null; read line; echo "read: $line"; exit 3')
case "$output" in *"read: hello"*) got=yes ;; *) got=no ;; esac
expect "the command can read the terminal" yes "$got"
expect "sleep is back afterwards" 0 "$(power)"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

output=$( (sleep 0.5; printf '\003'; sleep 0.5) | on_pty sh -c 'trap "echo got-interrupt; exit 9" INT; sleep 5 & wait')
case "$output" in *got-interrupt*) got=yes ;; *) got=no ;; esac
expect "Ctrl-C reaches the command" yes "$got"
expect "and sleep still comes back" 0 "$(power)"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

echo "=== 9. losing the session file ==="
"$wick" on 30m >/dev/null
sleep 1.3
printf 'garbage' > "$WICK_STATE_DIR/session.json"
wait_for 0 8; expect "a corrupt session ends rather than running unenforced" 0 "$(power)"
sleep 0.2; expect "and the guard leaves" 0 "$(settled_guards 0)"

"$wick" on 30m >/dev/null
sleep 1.3
rm "$WICK_STATE_DIR/session.json"
wait_for 0 8; expect "so does a deleted one" 0 "$(power)"

"$wick" on 30m >/dev/null
sleep 0.3
pkill -KILL -f "$wick guard"
printf 'garbage' > "$WICK_STATE_DIR/session.json"
"$wick" status >/dev/null
expect "reconciling handles a corrupt session with no guard" 0 "$(power)"

echo "=== 10. stopping and starting in a tight loop ==="
for _ in $(seq 1 25); do "$wick" off >/dev/null; "$wick" on 30m >/dev/null; done
sleep 7
expect "the last start wins" 1 "$(power)"
expect "with its session on disk" yes "$([ -f "$WICK_STATE_DIR/session.json" ] && echo yes || echo no)"
expect "and exactly one guard" 1 "$(settled_guards 1)"
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2

echo "=== 11. off --session-only ==="
echo 1 > "$WICK_SIMULATE_POWER_FILE"
"$wick" off --session-only
expect "leaves a setting Wick did not turn on" 1 "$(power)"
echo 0 > "$WICK_SIMULATE_POWER_FILE"

echo "=== 12. battery floor and thermal safety ==="
export WICK_SYSFS_ROOT="$work/sys"
mkdir -p "$WICK_SYSFS_ROOT/class/power_supply/BAT0"
bat="$WICK_SYSFS_ROOT/class/power_supply/BAT0"
echo Battery > "$bat/type"; echo Discharging > "$bat/status"
echo 50 > "$bat/capacity"
"$wick" on 30m --floor 20 >/dev/null
expect "on, with charge to spare" 1 "$(power)"
echo 15 > "$bat/capacity"
wait_for 0 8; expect "the battery falling to the floor restores sleep" 0 "$(power)"
expect "records lowBattery" lowBattery "$(last_reason)"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

output=$("$wick" on 30m 2>&1); code=$?
expect "starting below the floor is refused" 1 "$code"
case "$output" in *"15%"*) got=yes ;; *) got=no ;; esac
expect "and says so" yes "$got"
expect "and changes nothing" 0 "$(power)"
output=$("$wick" run echo hello 2>&1); code=$?
expect "wick run won't start unprotected either" 1 "$code"
case "$output" in *hello*) got=yes ;; *) got=no ;; esac
expect "and doesn't run the command" no "$got"
output=$("$wick" run --floor off echo hello 2>&1); code=$?
expect "unless told to" 0 "$code"
expect "and then runs it" hello "$output"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2
"$wick" on 30m --floor 10 >/dev/null
expect "a lower floor is fine" 1 "$(power)"
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2
unset WICK_SYSFS_ROOT

export WICK_SIMULATE_THERMAL="critical"
"$wick" on 30m >/dev/null
wait_for 0 5; expect "critical thermal restores sleep" 0 "$(power)"
expect "records overheating" overheating "$(last_reason)"
export WICK_SIMULATE_THERMAL=""
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

export WICK_SYSFS_ROOT="$work/sys" WICK_SIMULATE_LID=closed
echo Charging > "$bat/status"; echo 80 > "$bat/capacity"; echo 310 > "$bat/temp"
"$wick" on 30m >/dev/null
expect "status says how hot it is" "Heat: cool, battery 31°C, lid closed." "$("$wick" status | tail -1)"
sleep 6
expect "a cool laptop with the lid closed is what Wick is for" 1 "$(power)"
echo 460 > "$bat/temp"
started=$(date +%s)
case "$("$wick" status | tail -1)" in *"Wick stops if this lasts a minute."*) got=yes ;; *) got=no ;; esac
expect "status warns once the battery gets hot under a closed lid" yes "$got"
sleep 45
expect "which gets most of a minute" 1 "$(power)"
wait_for 0 30; expect "and is stopped once it has lasted one" 0 "$(power)"
lasted=$(($(date +%s) - started))
expect "not before the minute was up" yes "$([ "$lasted" -ge 55 ] && echo yes || echo "no, after ${lasted}s")"
expect "records overheating" overheating "$(last_reason)"
unset WICK_SYSFS_ROOT WICK_SIMULATE_LID
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

echo "=== 13. errors ==="
"$wick" on soon >/dev/null 2>&1
expect "bad duration fails" 1 "$?"
expect "and changes nothing" 0 "$(power)"
"$wick" on --floor 200 >/dev/null 2>&1
expect "bad floor fails" 1 "$?"
"$wick" nonsense >/dev/null 2>&1
expect "unknown command fails" 1 "$?"
for bad in inf nan 1e18 -5 0 ''; do
    output=$("$wick" on "$bad" 2>&1); code=$?
    expect "'$bad' is refused" 1 "$code"
    case "$output" in *Traceback*) got=yes ;; *) got=no ;; esac
    expect "and without a traceback" no "$got"
done
expect "none of which changed anything" 0 "$(power)"
"$wick" on 2h extra >/dev/null 2>&1
expect "stray arguments are refused" 1 "$?"
"$wick" run >/dev/null 2>&1
expect "run with no command is refused" 1 "$?"

echo "=== 14. wick run's exit codes ==="
"$wick" run sh -c 'kill -TERM $$'
expect "a command killed by a signal exits like a shell says" 143 "$?"
output=$("$wick" run sh -c 'exit 127' 2>&1); code=$?
expect "a command's own 127 passes through" 127 "$code"
expect "with no made-up error" "" "$output"
output=$("$wick" run /no/such/command 2>&1); code=$?
expect "a missing command is 127" 127 "$code"
case "$output" in *"command not found"*) got=yes ;; *) got=no ;; esac
expect "and says so" yes "$got"
expect "sleep is back after that" 0 "$(power)"
touch "$work/not-executable"
output=$("$wick" run "$work/not-executable" 2>&1); code=$?
expect "a command that can't execute is 126" 126 "$code"
case "$output" in *Traceback*) got=yes ;; *) got=no ;; esac
expect "without a traceback" no "$got"
expect "sleep is back after that too" 0 "$(power)"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

echo "=== 15. session files that can't be trusted ==="
for junk in '[]' 'null' '1' '{"heldPIDs":"oops"}' '{"startedAt":"2026-01-01T00:00:00Z","heldPIDs":["x"]}' '{"startedAt":"2026-01-01T00:00:00Z","endsAt":12}' '{"startedAt":"nope"}' '{"startedAt":"2026-01-01T00:00:00Z","batteryFloor":"low"}'; do
    "$wick" on 30m >/dev/null
    expect "on" 1 "$(power)"
    printf '%s' "$junk" > "$WICK_STATE_DIR/session.json"
    wait_for 0 8; expect "the guard ends on $junk" 0 "$(power)"
    expect "and leaves" 0 "$(settled_guards 0)"
done
"$wick" on 30m >/dev/null; sleep 0.3; pkill -KILL -f "$wick guard"; printf '[]' > "$WICK_STATE_DIR/session.json"
"$wick" status >/dev/null
expect "reconciling also ends valid JSON that isn't a session" 0 "$(power)"
sleep 0.2

echo "=== 16. wick set ==="
"$wick" set 2h >/dev/null 2>&1
expect "with no session, it refuses" 1 "$?"
expect "and doesn't revive one" no "$([ -f "$WICK_STATE_DIR/session.json" ] && echo yes || echo no)"
"$wick" on 1h >/dev/null
"$wick" set forever --agents on --floor 30 >/dev/null
got=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["endsAt"], s["untilAgentsFinish"], s["batteryFloor"])' "$WICK_STATE_DIR/session.json")
expect "it changes all of it" "None True 30" "$got"
"$wick" set 2h --agents off --floor off >/dev/null
got=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s["endsAt"] is not None, s["untilAgentsFinish"], s["batteryFloor"])' "$WICK_STATE_DIR/session.json")
expect "and back" "True False None" "$got"
for bad in "soon" "--agents maybe" "--floor 200" "1h 2h" ""; do
    # shellcheck disable=SC2086
    "$wick" set $bad >/dev/null 2>&1
    expect "'set $bad' is refused" 1 "$?"
done
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2
"$wick" run sh -c '"$0" set --agents on; sleep 1' "$wick" >/dev/null
expect "changing a session mid-command still ends it with the command" 0 "$(power)"
sleep 0.2; pkill -f "$wick guard"; sleep 0.2

echo "=== 17. what's saved, and the status output ==="
"$wick" on 1h --agents --floor 30 >/dev/null
keys=$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])))))' "$WICK_STATE_DIR/session.json")
expect "only real session fields are saved" "batteryFloor,endsAt,endsWithHeldProcesses,heldPIDs,lastAgentSeen,startedAt,untilAgentsFinish" "$keys"
json=$("$wick" status --json)
got=$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sleepDisabled"], d["session"]["batteryFloor"], d["session"]["untilAgentsFinish"], d["battery"]["percent"], type(d["agents"]).__name__)')
expect "status --json has what the GNOME extension needs" "True 30 True 80 list" "$got"
got=$(printf '%s' "$json" | python3 -c 'import json,sys; h=json.load(sys.stdin)["heat"]; print(h["word"] in ("Cool", "Warm", "Hot"), sorted(h))')
expect "including the heat" "True ['batteryCelsius', 'lidClosed', 'word']" "$got"
"$wick" off >/dev/null; sleep 0.1; pkill -f "$wick guard"; sleep 0.2
got=$("$wick" status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sleepDisabled"], d["session"], d["lastEnd"]["reason"])')
expect "and when idle" "False None stoppedByUser" "$got"

echo
[ "$failures" = 0 ] && echo "All passed." || echo "$failures failed."
exit "$failures"
