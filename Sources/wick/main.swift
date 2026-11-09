import Darwin
import Foundation
import WickCore

let usage = """
wick keeps your Mac awake with the lid closed.

  wick on [2h]             stay awake, for a duration or until `wick off`
      --agents             also stop when running coding agents finish
      --floor <percent>    stop at this battery level on battery (default 20, or "off")
  wick off                 back to normal sleep
  wick run <command...>    stay awake while a command runs, then go back to normal
  wick status [--json]     show the current state
  wick agents              list the coding agents Wick can see right now
  wick setup               allow Wick to change the setting without a password
  wick uninstall           remove that permission

Durations look like 90m, 2h or 1h30m.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("wick: \(message)\n".utf8))
    exit(code)
}

let executable = URL(filePath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()

func ensureAccess() {
    guard !Power.isAuthorized else { return }
    print("Wick needs your password once to change this setting. It adds one rule to \(Access.rulePath):\n")
    print(Access.rule())
    do {
        try Access.install()
    } catch {
        fail(error == .cancelled ? "permission was not granted." : "could not install the rule: \(error)")
    }
}

func start(_ session: Session) {
    ensureAccess()
    do {
        try Wick.start(session, guardExecutable: executable)
    } catch let error as PowerError {
        fail(error.sentence)
    } catch {
        fail("could not start: \(error)")
    }
}

/// Only a session has a guard watching the heat, so only then is stopping a promise.
func heatLine(_ heat: Heat, isGuarded: Bool) -> String {
    var parts = [heat.word.lowercased()]
    if let celsius = heat.batteryCelsius { parts.append("battery \(Int(celsius.rounded()))°C") }
    if let isLidClosed = heat.isLidClosed { parts.append(isLidClosed ? "lid closed" : "lid open") }
    let line = "Heat: \(parts.joined(separator: ", "))."
    return isGuarded && heat.isLidClosed == true && heat.isHot ? line + " Wick stops if this lasts a minute." : line
}

func printStatus() {
    let store = SessionStore()
    Wick.reconcile(guardExecutable: executable, store: store)
    let awake = Power.sleepDisabled() ?? false
    let heat = Heat.current()

    if CommandLine.arguments.contains("--json") {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Status: Encodable { var sleepDisabled: Bool; var session: Session?; var heat: Heat }
        let data = (try? encoder.encode(Status(sleepDisabled: awake, session: store.load(), heat: heat))) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return
    }

    guard awake else {
        print("Sleeping normally.")
        return
    }
    guard let session = store.load() else {
        print("Awake with the lid closed. Turned on outside Wick.")
        print(heatLine(heat, isGuarded: false))
        return
    }
    var line = "Awake with the lid closed"
    if let endsAt = session.endsAt {
        line += ", \(Durations.clock(endsAt.timeIntervalSinceNow)) left"
    }
    if session.untilAgentsFinish { line += ", or until agents finish" }
    if !session.heldPIDs.isEmpty { line += ", while a command runs" }
    print(line + ".")
    print(heatLine(heat, isGuarded: true))
}

func value(after flag: String, in arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count else { fail("\(flag) needs a value.") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func parseFloor(_ arguments: inout [String]) -> Int? {
    guard let text = value(after: "--floor", in: &arguments) else { return 20 }
    if text == "off" { return nil }
    guard let percent = Int(text), (1...99).contains(percent) else {
        fail("--floor takes a percentage from 1 to 99, or \"off\".")
    }
    return percent
}

func on(_ arguments: [String]) {
    var arguments = arguments
    let agents = arguments.contains("--agents")
    arguments.removeAll { $0 == "--agents" }

    let floor = parseFloor(&arguments)

    var endsAt: Date?
    if let text = arguments.first {
        guard let duration = Durations.parse(text) else { fail("\"\(text)\" is not a duration. Try 90m or 2h.") }
        endsAt = .now.addingTimeInterval(duration)
    }

    start(Session(endsAt: endsAt, untilAgentsFinish: agents, batteryFloor: floor))
    printStatus()
    if agents, endsAt == nil, Agents.running().isEmpty {
        print("No agents running yet. Wick waits for one to start, then stops when the last one exits.")
    }
}

func runCommand(_ arguments: [String]) -> Never {
    // Options come before the command, so that the command's own --floor stays its own.
    var arguments = arguments
    var floor: Int? = 20
    if arguments.first == "--floor" {
        var leading = Array(arguments.prefix(2))
        floor = parseFloor(&leading)
        arguments.removeFirst(min(2, arguments.count))
    }

    let command = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
    guard !command.isEmpty else { fail("wick run needs a command, like: wick run claude") }

    let store = SessionStore()
    Wick.reconcile(guardExecutable: executable, store: store)
    let pid = getpid()
    if store.update({ $0.heldPIDs.append(pid) }) == nil {
        start(Session(heldPIDs: [pid], endsWithHeldProcesses: true, batteryFloor: floor))
    }

    let status = runInForeground(command)

    // If this fails, the guard sees the held process has gone, and ends the session itself.
    try? Wick.releaseHold(pid: pid, store: store)
    guard let status else { fail("could not run \(command[0]).", code: 127) }
    exit(status)
}

/// posix_spawn rather than Process, because Process moves the child into a background process group, where
/// reading the terminal stops it dead and Ctrl-C never reaches it. Interactive agents need the terminal.
func runInForeground(_ command: [String]) -> Int32? {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    guard posix_spawnp(&pid, command[0], nil, nil, argv, environ) == 0 else { return nil }

    // Ctrl-C goes to the whole foreground group. Ignoring it only after the spawn, because the child inherits
    // ignored signals, keeps Wick alive to put sleep back while the command still gets to handle it.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    let signalNumber = status & 0x7F
    return signalNumber == 0 ? (status >> 8) & 0xFF : 128 + signalNumber
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "status" : arguments.removeFirst()

switch command {
case "on":
    on(arguments)
case "off":
    // Used by the Homebrew uninstall: end Wick's own session, but leave a setting someone else turned on alone.
    if arguments.contains("--session-only"), SessionStore().load() == nil { exit(0) }
    do {
        try Wick.stop()
    } catch PowerError.notAuthorized {
        fail("no permission yet. Run `wick setup` first.")
    } catch {
        fail("could not stop: \(error)")
    }
    print("Sleeping normally.")
case "run":
    runCommand(arguments)
case "status":
    printStatus()
case "agents":
    let agents = Agents.running()
    print(agents.isEmpty ? "No agents running." : agents.joined(separator: "\n"))
case "setup":
    ensureAccess()
    print("Ready. Wick can now change this setting without a password.")
case "uninstall":
    do {
        try Access.remove()
    } catch {
        fail("could not remove \(Access.rulePath): \(error)")
    }
    print("Permission removed.")
case "guard":
    Guard.run()
case "help", "--help", "-h":
    print(usage)
case "version", "--version":
    print("wick \(wickVersion)")
default:
    fail("unknown command \"\(command)\".\n\n\(usage)")
}
