#!/bin/bash
# The real thing: a real logind, a real polkit, a real unprivileged user, and Wick installed the way a user would
# install it, into a virtualenv with no D-Bus bindings. Runs inside a container started by run.sh.
set -u
failures=0
passes=0
expect() { # description expected actual
    if [ "$2" = "$3" ]; then echo "  ok    $1"; passes=$((passes + 1)); else echo "  FAIL  $1 (expected '$2', got '$3')"; failures=$((failures + 1)); fi
}
contains() { # description needle haystack
    case "$3" in *"$2"*) expect "$1" yes yes ;; *) expect "$1" "contains: $2" "$3" ;; esac
}
as_dev() { su dev -c "cd /home/dev; WICK_TEST=1 $*"; }

rm -rf /home/dev/src; cp -r /src /home/dev/src; chown -R dev: /home/dev/src
as_dev "python3 -m venv ~/venv && ~/venv/bin/pip -q install ~/src >/dev/null 2>&1"
W=/home/dev/venv/bin/wick
STATE=/home/dev/.local/state/wick
expect "pip installs a working wick" "wick 0.3.0" "$(as_dev "$W --version")"
expect "with no D-Bus bindings to lean on" 0 "$(as_dev "~/venv/bin/python -c 'import importlib.util as u; print(0 if u.find_spec(\"dbus\") is None else 1)'")"
expect "and the extension and icons in the package" 4 "$(find /home/dev/venv/lib -path '*wick/assets*' \( -name 'wick-*.svg' \) | wc -l)"

locks() { # Exactly what logind says, for Wick, for this user.
    busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors |
        python3 -c 'import json,sys,pwd; uid=pwd.getpwnam("dev").pw_uid; print(sum(1 for r in json.load(sys.stdin)["data"][0] if r[1]=="wick" and r[4]==uid and "handle-lid-switch" in r[0] and r[3]=="block"))'
}
leftovers() { pgrep -u dev -f 'wick guard|systemd-inhibit|kill -0' | wc -l | tr -d ' '; }
wait_locks() { # count seconds
    for _ in $(seq 1 $(($2 * 10))); do [ "$(locks)" = "$1" ] && return 0; sleep 0.1; done
    return 1
}
wait_leftovers() { for _ in $(seq 1 $(($1 * 10))); do [ "$(leftovers)" = 0 ] && return 0; sleep 0.1; done; return 1; }
reason() { # The record is written just after the lock goes, so give it a moment.
    for _ in $(seq 1 20); do [ -f "$STATE/last-end.json" ] && break; sleep 0.1; done
    sed -n 's/.*"reason": *"\([^"]*\)".*/\1/p' "$STATE/last-end.json" 2>/dev/null
}
guards() { # Spare guards retry the lock for a few seconds before they leave.
    for _ in $(seq 1 80); do [ "$(pgrep -u dev -f 'wick guard' | wc -l | tr -d ' ')" = "$1" ] && break; sleep 0.1; done
    pgrep -u dev -f 'wick guard' | wc -l | tr -d ' '
}
clean() {
    pkill -9 -u dev -f 'wick guard' 2>/dev/null; pkill -9 -u dev systemd-inhibit 2>/dev/null; wait_leftovers 4
    rm -rf "$STATE"
}

echo "--- refused: no active local session, the case over SSH"
clean
out=$(as_dev "$W on 1h" 2>&1); code=$?
expect "wick on fails" 1 "$code"
contains "and says why" "logind refused" "$out"
case "$out" in *Awake*) got=yes ;; *) got=no ;; esac
expect "and doesn't claim to be awake" no "$got"
case "$out" in *Traceback*) got=yes ;; *) got=no ;; esac
expect "without a traceback" no "$got"
expect "no lock" 0 "$(locks)"
expect "no session left behind" no "$([ -e "$STATE/session.json" ] && echo yes || echo no)"
wait_leftovers 8; expect "no processes left behind" 0 "$(leftovers)"
expect "status tells the truth" "Sleeping normally." "$(as_dev "$W status")"
as_dev "$W run true" >/dev/null 2>&1
expect "wick run fails rather than run without protection" 1 "$?"
doctor=$(as_dev "USER=dev $W doctor" 2>&1); code=$?
expect "doctor exits non-zero" 1 "$code"
contains "doctor says refused" "REFUSED" "$doctor"
contains "doctor gives the rule" "/etc/polkit-1/" "$doctor"
setup=$(as_dev "$W setup" 2>&1); code=$?
expect "setup exits non-zero" 1 "$code"
contains "setup gives the rule too" "/etc/polkit-1/" "$setup"
expect "and adds the launcher" yes "$([ -f /home/dev/.local/share/applications/io.github.s1lvazxy.wick.desktop ] && echo yes || echo no)"

echo "--- the rule doctor prints is the fix"
rule=$(printf '%s\n' "$doctor" | sed -n '/^cat > /,/^RULE$/p')
rule=${rule//your-user/dev}
mkdir -p /etc/polkit-1/rules.d /etc/polkit-1/localauthority/50-local.d; bash -c "$rule"
systemctl restart polkit 2>/dev/null; sleep 1
doctor=$(as_dev "USER=dev $W doctor" 2>&1); code=$?
expect "doctor now passes" 0 "$code"
contains "and says allowed" "allowed" "$doctor"
expect "probing leaves no lock behind" 0 "$(locks)"

echo "--- on and off"
clean
as_dev "$W on 1h" >/dev/null; code=$?
expect "on succeeds" 0 "$code"
expect "exactly one real lock as soon as it returns" 1 "$(locks)"
sleep 1
expect "still held once the CLI has exited" 1 "$(locks)"
contains "status" "Awake with the lid closed" "$(as_dev "$W status")"
expect "doctor agrees" yes "$(as_dev "$W doctor" | grep -q 'held by Wick' && echo yes || echo no)"
as_dev "$W off" >/dev/null
expect "off: the lock is gone the moment it returns" 0 "$(locks)"
wait_leftovers 3; expect "nothing left running" 0 "$(leftovers)"
expect "recorded" stoppedByUser "$(reason)"

echo "--- the guard dying must release the lock"
clean
as_dev "$W on 1h" >/dev/null; sleep 0.5
pkill -9 -u dev -f 'wick guard'
wait_locks 0 4; expect "SIGKILL: released within seconds, by nobody's cleanup" 0 "$(locks)"
wait_leftovers 4; expect "no orphans" 0 "$(leftovers)"
expect "status tells the truth" "Sleeping normally." "$(as_dev "$W status")"
expect "and the stale session is cleared" stoppedExternally "$(reason)"

clean
as_dev "$W on 1h" >/dev/null; sleep 0.5
pkill -TERM -u dev -f 'wick guard'
wait_locks 0 3; expect "SIGTERM, as at logout: released" 0 "$(locks)"
wait_leftovers 3; expect "no orphans" 0 "$(leftovers)"
expect "recorded" stoppedExternally "$(reason)"

clean
as_dev "$W on 1h" >/dev/null; sleep 0.5
pkill -9 -u dev systemd-inhibit
for _ in $(seq 1 80); do [ "$(leftovers)" = 0 ] && break; sleep 0.1; done
expect "someone kills the lock's holder: the guard notices and leaves" 0 "$(leftovers)"
expect "status tells the truth" "Sleeping normally." "$(as_dev "$W status")"
expect "recorded" stoppedExternally "$(reason)"

echo "--- the rules, against the real lock"
clean
as_dev "$W on 3s" >/dev/null
expect "held before the deadline" 1 "$(locks)"
wait_locks 0 6; expect "released at the deadline with nobody watching" 0 "$(locks)"
expect "recorded" timeUp "$(reason)"

clean
sys=/home/dev/fake-sys/class/power_supply/BAT0
as_dev "mkdir -p $sys; echo Battery > $sys/type; echo Discharging > $sys/status; echo 50 > $sys/capacity"
as_dev "WICK_SYSFS_ROOT=/home/dev/fake-sys $W on 1h" >/dev/null
expect "held on battery" 1 "$(locks)"
as_dev "echo 15 > $sys/capacity"
wait_locks 0 8; expect "the battery falling releases it" 0 "$(locks)"
expect "recorded" lowBattery "$(reason)"
out=$(as_dev "WICK_SYSFS_ROOT=/home/dev/fake-sys $W run echo ran" 2>&1); code=$?
expect "and wick run refuses to start below the floor" 1 "$code"
expect "with no lock" 0 "$(locks)"

clean
as_dev "WICK_SIMULATE_THERMAL=critical $W on 1h" >/dev/null
wait_locks 0 8; expect "heat releases it" 0 "$(locks)"
expect "recorded" overheating "$(reason)"

clean
during=$(as_dev "$W run sh -c 'busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors; exit 5'"); code=$?
contains "wick run: held while the command runs" '"wick"' "$during"
expect "the exit code passes through" 5 "$code"
expect "released when it finishes" 0 "$(locks)"

clean
as_dev "$W run sh -c 'kill -9 \$PPID; exec sleep 12'" >/dev/null 2>&1 &
wait_locks 0 10; expect "killing wick run ends it through the guard" 0 "$(locks)"
expect "recorded" commandFinished "$(reason)"
pkill -u dev -f 'exec sleep 12' 2>/dev/null; pkill -u dev -x sleep 2>/dev/null

clean
as_dev "$W run sleep 30" >/dev/null 2>&1 &
wait_locks 1 8; expect "wick run holds it" 1 "$(locks)"
pkill -9 -u dev -f 'wick guard'
wait_locks 0 4; expect "the guard dying during wick run still releases it" 0 "$(locks)"
expect "and leaves no zombie" 0 "$(ps -eo stat,args | grep -c '^Z.*wick')"
expect "and status tells the truth" "Sleeping normally." "$(as_dev "$W status")"
pkill -u dev -x sleep; wait 2>/dev/null

clean
as_dev "$W on 30m" >/dev/null
as_dev "$W run true" >/dev/null
expect "a run inside a session leaves it alone" 1 "$(locks)"
as_dev "$W set 2h --agents on" >/dev/null
expect "wick set leaves the lock alone" 1 "$(locks)"
as_dev "$W on 1h" >/dev/null; as_dev "$W on 2h" >/dev/null
expect "starting again replaces the session, not the lock" 1 "$(locks)"
expect "one guard" 1 "$(guards 1)"
as_dev "$W off" >/dev/null
expect "off" 0 "$(locks)"

echo "--- agents"
clean
su dev -s /bin/bash -c "exec -a claude sleep 400" >/dev/null 2>&1 &
sleep 0.5
expect "wick agents sees it" "Claude Code" "$(as_dev "$W agents")"
as_dev "$W on --agents" >/dev/null
sleep 6
expect "the guard writes down that it saw one" yes "$(grep -q '"lastAgentSeen": "' "$STATE/session.json" && echo yes || echo no)"
expect "held while it runs" 1 "$(locks)"
pkill -u dev -x sleep
# The grace period is 90 seconds, which is too long to wait here, so the note is aged instead.
python3 - "$STATE/session.json" <<'PY'
import json, sys, datetime
s = json.load(open(sys.argv[1]))
s["lastAgentSeen"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=120)).isoformat()
json.dump(s, open(sys.argv[1], "w"))
PY
wait_locks 0 8; expect "released once they've been gone long enough" 0 "$(locks)"
expect "recorded" agentsFinished "$(reason)"

echo "--- files that can't be trusted"
clean
as_dev "$W on 1h" >/dev/null; sleep 0.5
printf '{"heldPIDs":"oops"}' > "$STATE/session.json"
wait_locks 0 8; expect "a corrupt session releases the lock" 0 "$(locks)"
wait_leftovers 3; expect "and the guard leaves" 0 "$(leftovers)"
clean
as_dev "$W on 1h" >/dev/null; sleep 0.5
rm "$STATE/session.json"
wait_locks 0 8; expect "a deleted session releases it too" 0 "$(locks)"
clean
as_dev "sleep 300 &"
victim=$(pgrep -u dev -x sleep | head -1)
as_dev "$W on 1h" >/dev/null; sleep 0.5
printf '%s' "$victim" > "$STATE/guard.pid"
as_dev "$W off" >/dev/null; expect "with a stale pid file, off still succeeds" 0 "$?"
kill -0 "$victim" 2>/dev/null; expect "and can't kill someone else's process" 0 "$?"
expect "and the lock is gone when it returns" 0 "$(locks)"
pkill -u dev -x sleep

echo "--- under pressure"
clean
for _ in $(seq 1 25); do as_dev "$W off" >/dev/null; as_dev "$W on 30m" >/dev/null || echo "start failed"; done
sleep 1.5
expect "25 stop-starts leave exactly one lock" 1 "$(locks)"
expect "and one guard" 1 "$(guards 1)"
expect "and a session" yes "$([ -f "$STATE/session.json" ] && echo yes || echo no)"
as_dev "$W off" >/dev/null
expect "then off leaves none" 0 "$(locks)"
wait_leftovers 4; expect "and nothing running" 0 "$(leftovers)"

clean
pids=()
for _ in $(seq 1 8); do as_dev "$W on 30m" >/dev/null 2>&1 & pids+=($!); done
ok=0; for pid in "${pids[@]}"; do wait "$pid" && ok=$((ok + 1)); done
sleep 2
expect "8 concurrent starts all succeed" 8 "$ok"
expect "with one lock" 1 "$(locks)"
expect "and one guard" 1 "$(guards 1)"
as_dev "$W off" >/dev/null; expect "off" 0 "$(locks)"

# Random operations, checking after each one that what wick says matches what logind says.
clean
python3 - "$W" <<'PY'
import random, subprocess, sys, time
W = sys.argv[1]
random.seed(20261102)
def dev(cmd, check=False):
    return subprocess.run(["su", "dev", "-c", f"cd ~; {cmd}"], capture_output=True, text=True)
def locks():
    import json, pwd
    out = subprocess.run("busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors", shell=True, capture_output=True, text=True).stdout
    uid = pwd.getpwnam("dev").pw_uid
    return sum(1 for r in json.loads(out)["data"][0] if r[1] == "wick" and r[4] == uid and "handle-lid-switch" in r[0])
bad = 0
rounds = 60
for i in range(rounds):
    op = random.choice(["on", "on-timer", "off", "status", "run", "kill-guard", "term-guard", "corrupt"])
    if op == "on": r = dev(f"{W} on 1h")
    elif op == "on-timer": r = dev(f"{W} on {random.randint(1, 3)}s")
    elif op == "off": r = dev(f"{W} off")
    elif op == "status": r = dev(f"{W} status")
    elif op == "run": r = dev(f"{W} run true")
    elif op == "kill-guard": r = dev("pkill -9 -f 'wick guard'; sleep 2.5; true")
    elif op == "term-guard": r = dev("pkill -TERM -f 'wick guard'; sleep 1.5; true")
    else: r = dev("printf garbage > ~/.local/state/wick/session.json; sleep 6; true")
    if "Traceback" in r.stderr or "Traceback" in r.stdout:
        bad += 1; print("  TRACEBACK after", op, r.stderr[-300:])
    if op in ("off",) and locks() != 0:
        bad += 1; print(f"  round {i}: lock survived off")
    if op in ("on",) and r.returncode == 0 and locks() != 1:
        bad += 1; print(f"  round {i}: on returned but locks={locks()}")
    if locks() > 1:
        bad += 1; print(f"  round {i} after {op}: {locks()} locks")
    # Saying "Awake" with no lock, or "Sleeping" with one, is the bug that matters most.
    # A timer can legitimately end between the two reads, so a mismatch only counts if it lasts.
    s = dev(f"{W} status").stdout
    for attempt in range(6):
        held = locks()
        said = "Awake" in s
        if said == (held == 1): break
        time.sleep(1)
        s = dev(f"{W} status").stdout
    else:
        bad += 1; print(f"  round {i} after {op}: status={s.strip()!r} locks={held}")
dev(f"{W} off")
time.sleep(1)
print(f"  ok    {rounds} random operations, {bad} problems" if bad == 0 else f"  FAIL  {bad} problems in {rounds} random operations")
sys.exit(1 if bad else 0)
PY
[ "$?" = 0 ] && passes=$((passes + 1)) || failures=$((failures + 1))
expect "and nothing left at the end" 0 "$(locks)"

echo "--- what the lock actually does to logind"
clean
as_dev "$W on 1h" >/dev/null
expect "a real suspend request while held" 1 "$(locks)"
out=$(su dev -c "systemctl suspend --no-ask-password" 2>&1); code=$?
[ "$code" != 0 ] && got=refused || got=allowed
expect "logind refuses to suspend while the lock is held" refused "$got"
as_dev "$W off" >/dev/null

echo "--- a real lid switch"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/wick-test.conf <<'CONF'
[Login]
# "lock" so that a real lid event can't suspend the machine running these tests.
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=lock
HoldoffTimeoutSec=0
CONF
mkdir -p /etc/systemd/system/systemd-logind.service.d
printf '[Service]\nEnvironment=SYSTEMD_LOG_LEVEL=debug\n' > /etc/systemd/system/systemd-logind.service.d/debug.conf
control=/tmp/lid
lid_name="Wick Test Lid $(cat /proc/sys/kernel/hostname)"
python3 /src/tests/logind/fake_lid.py "$control" "$lid_name" > /tmp/lid.log 2>&1 &
lid_pid=$!
sleep 1
node=$(grep -lF "$lid_name" /sys/class/input/event*/device/name 2>/dev/null | head -1 | sed 's#/device/name##')
if [ -z "$node" ]; then
    echo "  skip  no uinput device here ($(cat /tmp/lid.log | tail -1))"
else
    event=$(basename "$node")
    numbers=$(cat "$node/dev")
    mkdir -p /dev/input
    [ -e "/dev/input/$event" ] || mknod "/dev/input/$event" c "${numbers%:*}" "${numbers#*:}"
    # logind finds switches through udev's records. udevd itself stays masked in this container, because it would
    # act on the host's devices, so the record the rules would have written is written by hand.
    mkdir -p /run/udev/data /run/udev/tags/power-switch
    printf 'E:ID_INPUT=1\nE:ID_INPUT_SWITCH=1\nG:power-switch\nQ:power-switch\nV:1\n' > "/run/udev/data/c$numbers"
    : > "/run/udev/tags/power-switch/c$numbers"
    systemctl daemon-reload
    systemctl restart systemd-logind
    sleep 2
    journal() { journalctl -u systemd-logind --since "$1" --no-pager -o cat 2>/dev/null; }
    if ! journal "-1min" | grep -q "Watching system buttons on /dev/input/$event"; then
        echo "  skip  logind isn't watching the virtual lid here"
    else
        expect "logind accepts the virtual lid as a real switch" yes yes

        since=$(date '+%Y-%m-%d %H:%M:%S'); sleep 1
        echo close > "$control"; sleep 2
        log=$(journal "$since")
        contains "with no lock, logind sees the lid close" "Lid closed" "$log"
        case "$log" in *"handle-lid-switch"*inhibited*|*"inhibited"*) got=inhibited ;; *) got=acted ;; esac
        expect "and acts on it" acted "$got"
        echo open > "$control"; sleep 2

        as_dev "$W on 1h" >/dev/null
        expect "with Wick on" 1 "$(locks)"
        since=$(date '+%Y-%m-%d %H:%M:%S'); sleep 1
        echo close > "$control"; sleep 2
        log=$(journal "$since")
        contains "logind sees the lid close" "Lid closed" "$log"
        contains "and refuses to act, because of the lock" "inhibited" "$log"
        echo open > "$control"; sleep 2

        as_dev "$W off" >/dev/null
        since=$(date '+%Y-%m-%d %H:%M:%S'); sleep 1
        echo close > "$control"; sleep 2
        log=$(journal "$since")
        case "$log" in *inhibited*) got=inhibited ;; *) got=acted ;; esac
        expect "after wick off, closing the lid works normally again" acted "$got"
        echo open > "$control"; sleep 1

        # Heat with the lid closed, with logind itself saying where the lid is.
        clean
        hot=/home/dev/hot-sys/class/power_supply/BAT0
        as_dev "mkdir -p $hot; echo Battery > $hot/type; echo Charging > $hot/status; echo 80 > $hot/capacity; echo 460 > $hot/temp"
        as_dev "WICK_SYSFS_ROOT=/home/dev/hot-sys $W on 1h" >/dev/null
        sleep 7
        expect "a hot battery with the lid open is left alone" 1 "$(locks)"
        # The last line, because the first says "Awake with the lid closed" whatever the lid is doing.
        heat=$(as_dev "WICK_SYSFS_ROOT=/home/dev/hot-sys $W status" | tail -1)
        contains "status says how hot it is" "Heat: hot, battery 46°C" "$heat"
        case "$heat" in *"lid closed"*) got=closed ;; *) got="not closed" ;; esac
        expect "and doesn't call the lid closed" "not closed" "$got"
        echo close > "$control"; sleep 2
        contains "wick asks logind, and sees the lid close" "battery 46°C, lid closed. Wick stops if this lasts a minute." "$(as_dev "WICK_SYSFS_ROOT=/home/dev/hot-sys $W status")"
        contains "so does wick doctor" "Lid           closed" "$(as_dev "WICK_SYSFS_ROOT=/home/dev/hot-sys $W doctor")"
        sleep 38
        expect "it gets most of a minute" 1 "$(locks)"
        wait_locks 0 40; expect "and is released once it has lasted one" 0 "$(locks)"
        expect "recorded" overheating "$(reason)"
        echo open > "$control"; sleep 1
    fi
fi
echo quit > "$control"; wait "$lid_pid" 2>/dev/null

echo
echo "$passes passed, $failures failed."
[ "$failures" = 0 ]
