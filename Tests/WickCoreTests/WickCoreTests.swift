import Foundation
import Testing
@testable import WickCore

@Suite struct `Reading pmset` {
    @Test func `reads the flag when on`() {
        #expect(Power.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby 1"))
    }

    @Test func `reads the flag when off`() {
        #expect(!Power.parseSleepDisabled(" SleepDisabled\t\t0\n"))
    }

    @Test func `a missing line means off`() {
        #expect(!Power.parseSleepDisabled("Currently in use:\n standby 1\n sleep 1"))
    }
}

@Suite struct `Session end rules` {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func conditions(
        battery: Battery? = Battery(percent: 80, isDischarging: false),
        hot: Bool = false,
        held: Bool = false
    ) -> Session.Conditions {
        .init(now: now, battery: battery, isOverheating: hot, anyHeldProcessAlive: held)
    }

    @Test func `an open session keeps running`() {
        #expect(Session().endReason(in: conditions()) == nil)
    }

    @Test func `ends at the deadline, not before`() {
        #expect(Session(endsAt: now).endReason(in: conditions()) == .timeUp)
        #expect(Session(endsAt: now.addingTimeInterval(1)).endReason(in: conditions()) == nil)
    }

    @Test func `battery floor only applies while discharging`() {
        let session = Session(batteryFloor: 20)
        #expect(session.endReason(in: conditions(battery: .init(percent: 20, isDischarging: true))) == .lowBattery)
        #expect(session.endReason(in: conditions(battery: .init(percent: 21, isDischarging: true))) == nil)
        #expect(session.endReason(in: conditions(battery: .init(percent: 5, isDischarging: false))) == nil)
    }

    @Test func `starting at the floor can be spotted up front`() {
        let low = Battery(percent: 15, isDischarging: true)
        let charging = Battery(percent: 15, isDischarging: false)
        let plenty = Battery(percent: 21, isDischarging: true)
        let withFloor = Session(batteryFloor: 20)
        let withoutFloor = Session(batteryFloor: nil)
        #expect(withFloor.isAtBatteryFloor(low) == true)
        #expect(withFloor.isAtBatteryFloor(charging) == false)
        #expect(withFloor.isAtBatteryFloor(plenty) == false)
        #expect(withoutFloor.isAtBatteryFloor(low) == false)
        #expect(withFloor.isAtBatteryFloor(nil) == false)
    }

    @Test func `no floor means the battery is ignored`() {
        let session = Session(batteryFloor: nil)
        #expect(session.endReason(in: conditions(battery: .init(percent: 1, isDischarging: true))) == nil)
    }

    @Test func `desktops have no battery to protect`() {
        #expect(Session().endReason(in: conditions(battery: nil)) == nil)
    }

    @Test func `heat outranks everything`() {
        let session = Session(endsAt: now, batteryFloor: 100)
        let hot = conditions(battery: .init(percent: 1, isDischarging: true), hot: true)
        #expect(session.endReason(in: hot) == .overheating)
    }

    @Test func `ends with its held command when it exists for one`() {
        let session = Session(heldPIDs: [42], endsWithHeldProcesses: true)
        #expect(session.endReason(in: conditions(held: true)) == nil)
        #expect(session.endReason(in: conditions(held: false)) == .commandFinished)
    }

    @Test func `an open session survives a command that joined it`() {
        #expect(Session(heldPIDs: []).endReason(in: conditions(held: false)) == nil)
    }

    @Test func `a running command outlives the timer`() {
        let session = Session(endsAt: now, heldPIDs: [42])
        #expect(session.endReason(in: conditions(held: true)) == nil)
        #expect(session.endReason(in: conditions(held: false)) == .timeUp)
    }

    @Test func `safety outranks a running command`() {
        let session = Session(heldPIDs: [42], batteryFloor: 20)
        let low = conditions(battery: .init(percent: 10, isDischarging: true), held: true)
        #expect(session.endReason(in: low) == .lowBattery)
        #expect(session.endReason(in: conditions(hot: true, held: true)) == .overheating)
    }

    @Test func `waits for an agent to appear before releasing`() {
        #expect(Session(untilAgentsFinish: true).endReason(in: conditions()) == nil)
    }

    @Test func `gives agents a grace period to restart`() {
        let justGone = now.addingTimeInterval(-(Session.agentGrace - 1))
        let longGone = now.addingTimeInterval(-Session.agentGrace)
        #expect(Session(untilAgentsFinish: true, lastAgentSeen: justGone).endReason(in: conditions()) == nil)
        #expect(Session(untilAgentsFinish: true, lastAgentSeen: longGone).endReason(in: conditions()) == .agentsFinished)
    }
}

@Suite struct `Agent matching` {
    @Test(arguments: [
        ("claude", [String](), "Claude Code"),
        ("codex", [], "Codex"),
        ("node", ["node", "/opt/homebrew/bin/codex"], "Codex"),
        ("node", ["node", "/usr/local/lib/claude.js"], "Claude Code"),
        ("python3", ["python3", "/Users/me/.local/bin/aider"], "Aider"),
        ("2.1.312", ["claude"], "Claude Code"),
        ("2.1.312", ["/Users/me/.local/bin/claude", "--resume"], "Claude Code"),
    ])
    func `finds agents`(process: String, arguments: [String], expected: String) {
        #expect(Agents.match(processName: process, arguments: arguments) == expected)
    }

    @Test(arguments: [
        ("Claude", [String]()),
        ("node", ["node", "server.js"]),
        ("node", []),
        ("zsh", []),
        ("zsh", ["zsh", "claude"]),
        ("vim", ["vim", "codex"]),
    ])
    func `ignores everything else`(process: String, arguments: [String]) {
        #expect(Agents.match(processName: process, arguments: arguments) == nil)
    }
}

@Suite struct Durations_ {
    @Test(arguments: [
        ("90", 5400.0), ("90m", 5400), ("2h", 7200), ("1h30m", 5400), ("45s", 45), ("2H", 7200),
    ])
    func `parses`(text: String, seconds: TimeInterval) {
        #expect(Durations.parse(text) == seconds)
    }

    @Test(arguments: ["", "soon", "0", "-5", "2x", "h", "1h soon"])
    func `rejects`(text: String) {
        #expect(Durations.parse(text) == nil)
    }

    @Test func `clock formats`() {
        #expect(Durations.clock(6129) == "1:42:09")
        #expect(Durations.clock(59.2) == "1:00")
        #expect(Durations.clock(-3) == "0:00")
    }

    @Test func `compact formats`() {
        #expect(Durations.compact(7500) == "2h 05m")
        #expect(Durations.compact(2520) == "42m")
        #expect(Durations.compact(30) == "<1m")
        #expect(Durations.compact(3599) == "1h 00m")
    }
}

@Suite struct `Sudoers rule` {
    @Test func `allows only the two exact commands`() {
        let rule = Access.rule(user: "ana", uid: 501)
        #expect(rule.contains("ana ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"))
        #expect(!rule.contains("ALL=(ALL)"))
        #expect(!rule.contains("*"))
    }

    @Test(arguments: ["ana ALL=(ALL) ALL\n#", "a b", "ana,root", "%admin", ""])
    func `falls back to the uid for names that are not plain`(name: String) {
        #expect(Access.sudoersUser(name, uid: 501) == "#501")
    }

    @Test func `visudo accepts the rule`() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "wick-rule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Access.rule(user: "ana", uid: 501).write(to: file, atomically: true, encoding: .utf8)
        #expect(Shell.run("/usr/sbin/visudo", ["-cqf", file.path]).status == 0)
    }

    @Test func `the install script validates before it installs`() throws {
        let script = Access.installScript(rule: "x\n")
        let validate = try #require(script.range(of: "visudo -cqf"))
        let install = try #require(script.range(of: "/usr/bin/install"))
        #expect(validate.lowerBound < install.lowerBound)
        #expect(script.contains("set -eu"))
    }

    @Test func `the install script is valid shell`() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "wick-install-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: file) }
        try Access.installScript(rule: Access.rule(user: "ana", uid: 501)).write(to: file, atomically: true, encoding: .utf8)
        #expect(Shell.run("/bin/sh", ["-n", file.path]).status == 0)
    }

    @Test func `removing ends a running session in the same privileged step`() {
        #expect(Access.removeScript(restoringSleep: true).hasPrefix("/usr/bin/pmset -a disablesleep 0;"))
        #expect(!Access.removeScript(restoringSleep: false).contains("pmset"))
    }

    @Test func `quotes survive the trip through AppleScript`() {
        let script = Access.appleScript(running: #"echo "a\b""#, prompt: "p")
        #expect(script.contains(#"echo \"a\\b\""#))
    }
}

@Suite struct `Session file` {
    func store() -> SessionStore {
        SessionStore(directory: FileManager.default.temporaryDirectory.appending(path: "wick-\(UUID().uuidString)"))
    }

    @Test func `round trips`() throws {
        let store = store()
        let session = Session(
            startedAt: Date(timeIntervalSince1970: 1000),
            endsAt: Date(timeIntervalSince1970: 2000),
            untilAgentsFinish: true,
            heldPIDs: [7],
            batteryFloor: 30
        )
        try store.save(session)
        #expect(store.load() == session)
    }

    @Test func `finishing clears the session and records why`() throws {
        let store = store()
        try store.save(Session())
        store.finish(.lowBattery)
        #expect(store.load() == nil)
        #expect(store.lastEnd()?.reason == .lowBattery)
    }

    @Test func `a corrupt file reads as no session, and is flagged`() throws {
        let store = store()
        try store.save(Session())
        #expect(!store.hasUnreadableSession)
        try Data("nope".utf8).write(to: store.sessionURL)
        #expect(store.load() == nil)
        #expect(store.hasUnreadableSession)
    }

    @Test func `update changes a live session and refuses to revive an ended one`() throws {
        let store = store()
        #expect(store.update { $0.heldPIDs.append(1) } == nil)
        #expect(store.load() == nil)

        try store.save(Session())
        #expect(store.update { $0.heldPIDs.append(1) }?.heldPIDs == [1])
        #expect(store.load()?.heldPIDs == [1])
    }
}

@Suite struct `Guard launchd job` {
    @Test func `is a valid property list that runs the guard`() throws {
        let data = try GuardAgent.propertyList(executable: URL(filePath: "/Applications/Wick.app/Contents/Helpers/wick"))
        let file = FileManager.default.temporaryDirectory.appending(path: "wick-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        #expect(Shell.run("/usr/bin/plutil", ["-lint", file.path]).status == 0)

        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/Wick.app/Contents/Helpers/wick", "guard"])
        #expect(plist["RunAtLoad"] as? Bool == true)
    }
}

/// The guard's side of it: one watch, asked again and again as time passes.
private final class Watching {
    private var watch = HeatWatch()

    func isOverheating(_ heat: Heat, at uptime: TimeInterval) -> Bool {
        watch.isOverheating(heat, uptime: uptime)
    }

    /// Asks every five seconds, as the guard does, and answers with the last reply.
    func isOverheating(_ heat: Heat, for seconds: TimeInterval, from start: TimeInterval = 0) -> Bool {
        var answer = false
        for uptime in stride(from: start, through: start + seconds, by: 5) {
            answer = isOverheating(heat, at: uptime)
        }
        return answer
    }
}

@Suite struct `Heat rules` {
    func heat(_ level: Heat.Level = .nominal, lid isLidClosed: Bool? = true, battery: Double? = 31) -> Heat {
        Heat(level: level, isLidClosed: isLidClosed, batteryCelsius: battery)
    }

    @Test func `critical stops at once, lid open or closed`() {
        for isLidClosed in [true, false, nil] {
            #expect(Watching().isOverheating(heat(.critical, lid: isLidClosed), at: 0))
        }
    }

    @Test func `serious with the lid closed has to last a minute`() {
        let guarded = Watching()
        #expect(!guarded.isOverheating(heat(.serious), for: 55))
        #expect(guarded.isOverheating(heat(.serious), at: 60))
    }

    @Test func `serious with the lid open never stops it`() {
        #expect(!Watching().isOverheating(heat(.serious, lid: false), for: 3600))
    }

    @Test func `not knowing about the lid counts as open`() {
        #expect(!Watching().isOverheating(heat(.serious, lid: nil, battery: 50), for: 3600))
    }

    @Test func `a hot battery with the lid closed stops it after a minute`() {
        let guarded = Watching()
        #expect(!guarded.isOverheating(heat(battery: 45), for: 55))
        #expect(guarded.isOverheating(heat(battery: 45), at: 60))
    }

    @Test func `a battery just under the line is fine`() {
        #expect(!Watching().isOverheating(heat(.fair, battery: 44.9), for: 3600))
    }

    @Test func `a cool sample starts the minute again`() {
        let guarded = Watching()
        #expect(!guarded.isOverheating(heat(.serious), for: 55))
        #expect(!guarded.isOverheating(heat(.fair), at: 60))
        #expect(!guarded.isOverheating(heat(.serious), for: 55, from: 65))
        #expect(guarded.isOverheating(heat(.serious), at: 125))
    }

    @Test func `opening the lid starts the minute again`() {
        let guarded = Watching()
        #expect(!guarded.isOverheating(heat(.serious), for: 55))
        #expect(!guarded.isOverheating(heat(.serious, lid: false), at: 60))
        #expect(!guarded.isOverheating(heat(.serious), at: 65))
    }

    @Test func `being asked often doesn't make it trigger sooner`() {
        let guarded = Watching()
        for tenth in 0..<590 {
            #expect(!guarded.isOverheating(heat(.serious), at: Double(tenth) / 10))
        }
    }

    @Test(arguments: [0, -273.15, 0.5, 100.5, 6280, .infinity, .nan])
    func `battery readings that can't be real are ignored`(celsius: Double) {
        #expect(heat(battery: celsius).batteryCelsius == nil)
        #expect(!Watching().isOverheating(heat(battery: celsius), for: 3600))
    }

    @Test func `sums up as a word`() {
        #expect(heat().word == "Cool")
        #expect(heat(.fair).word == "Warm")
        #expect(heat(battery: 40).word == "Warm")
        #expect(heat(.serious).word == "Hot")
        #expect(heat(battery: 45).word == "Hot")
        #expect(heat(.critical, battery: nil).word == "Hot")
    }

    @Test func `the simulation file takes words in any order`() {
        #expect(Heat.parse("serious closed 46\n") == heat(.serious, lid: true, battery: 46))
        #expect(Heat.parse("44.5 open") == heat(.nominal, lid: false, battery: 44.5))
        #expect(Heat.parse("") == heat(.nominal, lid: nil, battery: nil))
        #expect(Heat.parse("critical") == heat(.critical, lid: nil, battery: nil))
    }

    @Test func `status prints unknowns as null rather than leaving them out`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let unknown = try encoder.encode(heat(.fair, lid: nil, battery: nil))
        #expect(String(decoding: unknown, as: UTF8.self) == #"{"batteryCelsius":null,"level":"fair","lidClosed":null,"word":"Warm"}"#)
        let known = try encoder.encode(heat(.nominal, lid: true, battery: 31))
        #expect(String(decoding: known, as: UTF8.self) == #"{"batteryCelsius":31,"level":"nominal","lidClosed":true,"word":"Cool"}"#)
    }

    @Test func `levels are in order`() {
        #expect(Heat.Level.allCases == Heat.Level.allCases.sorted())
        #expect(Heat.Level.serious < .critical)
    }
}
