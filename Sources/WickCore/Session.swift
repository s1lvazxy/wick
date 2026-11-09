import Darwin
import Foundation

public enum EndReason: String, Codable, Sendable {
    case timeUp
    case agentsFinished
    case commandFinished
    case lowBattery
    case overheating
    case stoppedByUser
    case stoppedExternally

    public var sentence: String {
        switch self {
        case .timeUp: "Time's up. Sleep is back to normal."
        case .agentsFinished: "Agents finished. Sleep is back to normal."
        case .commandFinished: "Command finished. Sleep is back to normal."
        case .lowBattery: "Stopped to protect the battery."
        case .overheating: "Stopped to let the Mac cool down."
        case .stoppedByUser: "Stopped."
        case .stoppedExternally: "Sleep was turned back on outside Wick."
        }
    }
}

/// A period during which the Mac stays awake with the lid closed. The file on disk is the single source of
/// truth: the app and the CLI write it, and the guard process enforces it even if both of them are gone.
public struct Session: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var endsAt: Date?
    public var untilAgentsFinish: Bool
    /// Processes keeping the session alive past its timer, from `wick run`.
    public var heldPIDs: [Int32]
    /// The session exists only for those processes, and ends with them.
    public var endsWithHeldProcesses: Bool
    public var batteryFloor: Int?
    /// On disk, not in the guard's memory, so a restarted guard still knows the agents have gone.
    public var lastAgentSeen: Date?

    public init(
        startedAt: Date = .now,
        endsAt: Date? = nil,
        untilAgentsFinish: Bool = false,
        heldPIDs: [Int32] = [],
        endsWithHeldProcesses: Bool = false,
        batteryFloor: Int? = 20,
        lastAgentSeen: Date? = nil
    ) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.untilAgentsFinish = untilAgentsFinish
        self.heldPIDs = heldPIDs
        self.endsWithHeldProcesses = endsWithHeldProcesses
        self.batteryFloor = batteryFloor
        self.lastAgentSeen = lastAgentSeen
    }

    /// How long agents must be gone before the session ends, so a restarted agent doesn't drop the Mac to sleep.
    public static let agentGrace: TimeInterval = 90

    public struct Conditions: Sendable {
        public var now: Date
        public var battery: Battery?
        public var isOverheating: Bool
        public var anyHeldProcessAlive: Bool

        public init(now: Date, battery: Battery?, isOverheating: Bool, anyHeldProcessAlive: Bool) {
            self.now = now
            self.battery = battery
            self.isOverheating = isOverheating
            self.anyHeldProcessAlive = anyHeldProcessAlive
        }
    }

    /// Whether the battery alone would end this session, which is worth knowing before starting it.
    public func isAtBatteryFloor(_ battery: Battery?) -> Bool {
        guard let batteryFloor, let battery else { return false }
        return battery.isDischarging && battery.percent <= batteryFloor
    }

    /// Safety outranks everything else the session asked for.
    public func endReason(in conditions: Conditions) -> EndReason? {
        if conditions.isOverheating { return .overheating }
        if isAtBatteryFloor(conditions.battery) { return .lowBattery }
        // A command that's still running outlives the timer: `wick on 10m; wick run build` shouldn't sleep mid-build.
        if let endsAt, conditions.now >= endsAt, !conditions.anyHeldProcessAlive { return .timeUp }
        if endsWithHeldProcesses, !conditions.anyHeldProcessAlive { return .commandFinished }
        if untilAgentsFinish, let lastAgentSeen,
           conditions.now.timeIntervalSince(lastAgentSeen) >= Self.agentGrace {
            return .agentsFinished
        }
        return nil
    }
}

public struct SessionEnd: Codable, Sendable, Equatable {
    public var reason: EndReason
    public var at: Date

    public init(reason: EndReason, at: Date = .now) {
        self.reason = reason
        self.at = at
    }
}

public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WICK_STATE_DIR"] {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Wick", directoryHint: .isDirectory)
    }

    var sessionURL: URL { directory.appending(path: "session.json") }
    var lastEndURL: URL { directory.appending(path: "last-end.json") }
    var guardLockURL: URL { directory.appending(path: "guard.lock") }
    var stateLockURL: URL { directory.appending(path: "state.lock") }

    public func load() -> Session? { read(sessionURL) }
    public func lastEnd() -> SessionEnd? { read(lastEndURL) }

    /// A file that's there but can't be decoded. Nothing can enforce it, so it has to be treated as an end.
    var hasUnreadableSession: Bool {
        load() == nil && FileManager.default.fileExists(atPath: sessionURL.path)
    }

    /// Serialises every read-then-write of the setting and the session across the app, the CLI and the guard.
    /// Without it, a guard mid-check can delete a session that `wick on` has just written.
    /// Not reentrant: never nest it.
    public func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // O_CLOEXEC: a child process inheriting this descriptor would hold the lock for as long as it lives.
        let descriptor = open(stateLockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer { if descriptor >= 0 { close(descriptor) } }
        return try body()
    }

    /// Changes the session on disk if there still is one. Returns the result, or nil if it has ended.
    @discardableResult
    public func update(_ change: (inout Session) -> Void) -> Session? {
        withLock {
            guard var session = load() else { return nil }
            change(&session)
            return (try? save(session)) == nil ? nil : session
        }
    }

    public func save(_ session: Session) throws {
        try write(session, to: sessionURL)
    }

    func discardSession() {
        try? FileManager.default.removeItem(at: sessionURL)
    }

    public func finish(_ reason: EndReason, at date: Date = .now) {
        try? FileManager.default.removeItem(at: sessionURL)
        try? write(SessionEnd(reason: reason, at: date), to: lastEndURL)
    }

    private func read<Value: Decodable>(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Value.self, from: data)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
