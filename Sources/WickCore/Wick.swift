import Darwin
import Foundation
import os

private let log = Logger(subsystem: "io.github.s1lvazxy.wick", category: "guard")

/// The operations the app and the CLI share.
public enum Wick {
    /// Turns sleep off, records the session, and starts the guard that will turn it back on.
    public static func start(
        _ session: Session,
        guardExecutable: URL,
        store: SessionStore = SessionStore()
    ) throws {
        // The guard's first check would end this straight away, and whatever was counting on it would run unprotected.
        let battery = Battery.current()
        if session.isAtBatteryFloor(battery), let battery, let floor = session.batteryFloor {
            throw PowerError.atBatteryFloor(percent: battery.percent, floor: floor)
        }

        GuardAgent.install(executable: guardExecutable)
        try store.withLock {
            var session = session
            // Starting over a session mustn't drop the commands relying on it, but only ones still running: a dead
            // PID copied into a new session could later belong to another process and hold the timer open forever.
            if let running = store.load(), Guard.startedThisBoot(running) {
                let stillHeld = running.heldPIDs.filter { !session.heldPIDs.contains($0) && Guard.isAlive($0) }
                session.heldPIDs += stillHeld
            }
            try store.save(session)
            do {
                try Power.setSleepDisabled(true)
            } catch {
                store.discardSession()
                throw error
            }
        }
        do {
            try Guard.spawn(executable: guardExecutable)
        } catch {
            // With no guard, the promise to turn sleep back on can't be kept. Better not to start.
            try? stop(.stoppedExternally, store: store)
            throw error
        }
    }

    public static func stop(_ reason: EndReason = .stoppedByUser, store: SessionStore = SessionStore()) throws {
        try store.withLock {
            try Power.setSleepDisabled(false)
            store.finish(reason)
        }
    }

    /// A `wick run` finishing. Removing its hold and ending the session it created have to be one step, or a session
    /// started in between would be ended too, after being told it was running.
    public static func releaseHold(pid: Int32, store: SessionStore = SessionStore()) throws {
        try store.withLock {
            guard var session = store.load() else { return }
            session.heldPIDs.removeAll { $0 == pid }
            if session.endsWithHeldProcesses, session.heldPIDs.isEmpty {
                try Power.setSleepDisabled(false)
                store.finish(.commandFinished)
            } else {
                try store.save(session)
            }
        }
    }

    /// Run on launch: picks up a session whose guard died with a reboot or a SIGKILL.
    public static func reconcile(guardExecutable: URL, store: SessionStore = SessionStore()) {
        let needsGuard = store.withLock {
            if store.hasUnreadableSession {
                if (try? Power.setSleepDisabled(false)) != nil { store.finish(.stoppedExternally) }
                return false
            }
            guard store.load() != nil else { return false }
            if Power.sleepDisabled() == false {
                store.finish(.stoppedExternally)
                return false
            }
            return true
        }
        if needsGuard { try? Guard.spawn(executable: guardExecutable) }
    }
}

/// Background process that enforces a session: the dead man's switch behind every safety promise Wick makes.
/// It keeps working if the app crashes or the terminal that ran `wick on` closes.
public enum Guard {
    private static let tick: TimeInterval = 5
    /// How often "an agent is still running" gets written down. Shorter than the grace period, on purpose.
    private static let agentNoteInterval: TimeInterval = 60

    public static func spawn(executable: URL) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
        }

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path), strdup("guard"), nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    }

    public static func run(store: SessionStore = SessionStore()) -> Never {
        guard acquireLock(store) else { exit(0) }

        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        // Logout and shutdown arrive as SIGTERM. Dying while holding sleep off would leave the Mac stuck awake.
        let release: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                try? Wick.stop(.stoppedExternally, store: store)
                exit(0)
            }
            source.resume()
            return source
        }

        withExtendedLifetime(release) {
            var isEnforcing = false
            // Lives here, between ticks. A guard restarted by launchd starts counting the minute again.
            var heat = HeatWatch()
            while true {
                let session = enforce(store: store, isEnforcing: &isEnforcing, heat: &heat)
                let untilDeadline = session?.endsAt.map { $0.timeIntervalSinceNow } ?? tick
                Thread.sleep(forTimeInterval: min(tick, max(untilDeadline, 0.5)))
            }
        }
        exit(0)
    }

    /// One tick, all of it under the state lock. Exits the process once there's nothing left to enforce.
    private static func enforce(store: SessionStore, isEnforcing: inout Bool, heat: inout HeatWatch) -> Session? {
        store.withLock {
            guard var session = store.load() else {
                // `stop` removes the file only after sleep is back on. If it's gone or unreadable with sleep
                // still off, nobody can say when this should end, and the safe answer is now.
                if isEnforcing, Power.sleepDisabled() == true {
                    guard (try? Power.setSleepDisabled(false)) != nil else {
                        log.error("Lost the session, and couldn't turn sleep back on. Retrying.")
                        return nil
                    }
                    store.finish(.stoppedExternally)
                }
                exit(0)
            }
            isEnforcing = true

            if Power.sleepDisabled() == false {
                store.finish(.stoppedExternally)
                exit(0)
            }

            if session.untilAgentsFinish, !Agents.running().isEmpty {
                let isStale = session.lastAgentSeen.map { Date.now.timeIntervalSince($0) >= agentNoteInterval } ?? true
                if isStale {
                    session.lastAgentSeen = .now
                    try? store.save(session)
                }
            }

            let conditions = Session.Conditions(
                now: .now,
                battery: Battery.current(),
                isOverheating: heat.isOverheating(.current(), uptime: ProcessInfo.processInfo.systemUptime),
                anyHeldProcessAlive: anyHeldProcessAlive(session)
            )
            if let reason = session.endReason(in: conditions) {
                do {
                    try Power.setSleepDisabled(false)
                    store.finish(reason)
                    exit(0)
                } catch {
                    log.error("Couldn't turn sleep back on after \(reason.rawValue, privacy: .public). Retrying.")
                }
            }
            return session
        }
    }

    static func startedThisBoot(_ session: Session) -> Bool {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var query = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&query, 2, &bootTime, &size, nil, 0) == 0 else { return true }
        return session.startedAt.timeIntervalSince1970 >= Double(bootTime.tv_sec)
    }

    /// PIDs from before the last boot mean nothing, whatever process has them now.
    private static func anyHeldProcessAlive(_ session: Session) -> Bool {
        startedThisBoot(session) && session.heldPIDs.contains(where: isAlive)
    }

    /// One guard at a time. The kernel drops the lock when the process dies, however it dies.
    /// Retries briefly: a guard that has just seen "no session" may still hold the lock on its way out,
    /// and giving up then would leave the new session with nobody watching it.
    private static func acquireLock(_ store: SessionStore) -> Bool {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let descriptor = open(store.guardLockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return false }
        for _ in 0..<10 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// A launchd job that runs the guard at login and every few minutes. It does nothing unless a session exists,
/// and exists for the cases a spawned guard can't cover: a SIGKILL, a crash of the whole Mac, a power cut.
enum GuardAgent {
    static let label = "io.github.s1lvazxy.wick.guard"

    private static var plistURL: URL {
        URL.libraryDirectory.appending(path: "LaunchAgents/\(label).plist")
    }

    private static var domain: String { "gui/\(getuid())" }

    /// Tests run against a temporary state directory, and must leave launchd alone.
    private static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["WICK_SIMULATE_POWER_FILE"] == nil && environment["WICK_STATE_DIR"] == nil
    }

    static func propertyList(executable: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": label,
                "ProgramArguments": [executable.path, "guard"],
                "RunAtLoad": true,
                "StartInterval": 300,
                "ProcessType": "Background",
            ] as [String: Any],
            format: .xml,
            options: 0
        )
    }

    /// Only touches launchd when something changed, such as the app having moved.
    static func install(executable: URL) {
        guard isEnabled, let plist = try? propertyList(executable: executable) else { return }
        if (try? Data(contentsOf: plistURL)) == plist { return }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plist.write(to: plistURL, options: .atomic)
        } catch {
            log.error("Couldn't write the guard's launchd job: \(error.localizedDescription, privacy: .public)")
            return
        }
        _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        _ = Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
    }

    static func remove() {
        guard isEnabled else { return }
        _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }
}
