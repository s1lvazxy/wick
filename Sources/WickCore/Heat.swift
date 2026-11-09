import Foundation
import IOKit

/// One look at how hot the Mac is, and whether its lid is letting that heat out.
public struct Heat: Sendable, Equatable, Encodable {
    /// macOS's own verdict, in order, so "serious or worse" is a comparison.
    public enum Level: String, Sendable, Comparable, CaseIterable, Encodable {
        case nominal, fair, serious, critical

        private var rank: Int {
            switch self {
            case .nominal: 0
            case .fair: 1
            case .serious: 2
            case .critical: 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

        init(_ state: ProcessInfo.ThermalState) {
            self = switch state {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .critical
            }
        }
    }

    /// Lithium cells shouldn't sit above this, and a battery only gets there when the whole case is hot.
    public static let hotBatteryCelsius = 45.0
    static let warmBatteryCelsius = 40.0
    /// Sensors that aren't really reading report things like 0 and 6280.
    static let plausibleBatteryCelsius = 1.0...100.0

    public var level: Level
    /// `nil` on a Mac with no lid. Not knowing counts as open.
    public var isLidClosed: Bool?
    /// `nil` without a battery, or when the sensor reads nonsense.
    public private(set) var batteryCelsius: Double?

    public init(level: Level, isLidClosed: Bool?, batteryCelsius: Double?) {
        self.level = level
        self.isLidClosed = isLidClosed
        self.batteryCelsius = batteryCelsius.flatMap { Self.plausibleBatteryCelsius.contains($0) ? $0 : nil }
    }

    /// Hot enough to end a session, if the lid is closed and it lasts.
    public var isHot: Bool {
        level >= .serious || (batteryCelsius ?? 0) >= Self.hotBatteryCelsius
    }

    public var isWarm: Bool {
        level >= .fair || (batteryCelsius ?? 0) >= Self.warmBatteryCelsius
    }

    /// The whole reading as one word, for the panel and `wick status`.
    public var word: String {
        isHot ? "Hot" : isWarm ? "Warm" : "Cool"
    }

    /// The shape `wick status --json` prints, with the same names as on Linux. Unknowns are said, not left out.
    public func encode(to encoder: any Encoder) throws {
        enum Key: String, CodingKey { case level, word, lidClosed, batteryCelsius }
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(level, forKey: .level)
        try container.encode(word, forKey: .word)
        try container.encode(isLidClosed, forKey: .lidClosed)
        try container.encode(batteryCelsius, forKey: .batteryCelsius)
    }

    /// Replaces the real sensors with a file holding words like `serious closed 46`, so scripts/e2e.sh can drive
    /// both rungs. A simulated power setting with no such file reads as a cool Mac, never as this one.
    private static let simulatedFile = ProcessInfo.processInfo.environment["WICK_SIMULATE_HEAT_FILE"]
    private static let isSimulatingPower = ProcessInfo.processInfo.environment["WICK_SIMULATE_POWER_FILE"] != nil

    public static func current() -> Heat {
        if let simulatedFile {
            return parse((try? String(contentsOfFile: simulatedFile, encoding: .utf8)) ?? "")
        }
        if isSimulatingPower { return parse("") }
        return Heat(
            level: Level(ProcessInfo.processInfo.thermalState),
            isLidClosed: registryValue(of: "IOPMrootDomain", key: "AppleClamshellState") as? Bool,
            // Hundredths of a degree: 3107 is 31.07°C.
            batteryCelsius: (registryValue(of: "AppleSmartBattery", key: "Temperature") as? NSNumber)
                .map { $0.doubleValue / 100 }
        )
    }

    /// Words in any order: a level, `open` or `closed`, and a battery temperature in °C. Anything missing is unknown.
    static func parse(_ text: String) -> Heat {
        var heat = Heat(level: .nominal, isLidClosed: nil, batteryCelsius: nil)
        for word in text.split(whereSeparator: \.isWhitespace) {
            if let level = Level(rawValue: String(word)) {
                heat.level = level
            } else if word == "closed" || word == "open" {
                heat.isLidClosed = word == "closed"
            } else if let celsius = Double(word) {
                heat = Heat(level: heat.level, isLidClosed: heat.isLidClosed, batteryCelsius: celsius)
            }
        }
        return heat
    }

    private static func registryValue(of service: String, key: String) -> Any? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(service))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// Decides when heat ends a session. Two rungs: a critical Mac stops at once, lid open or closed, and a hot Mac
/// with its lid closed stops once that has lasted, because one hot sample in the middle of a build means nothing.
public struct HeatWatch: Sendable {
    public static let sustained: TimeInterval = 60

    private var hotSince: TimeInterval?

    public init() {}

    /// `uptime` only has to count forwards, like `ProcessInfo.systemUptime`: the wall clock can be changed.
    public mutating func isOverheating(_ heat: Heat, uptime: TimeInterval) -> Bool {
        if heat.level == .critical { return true }
        guard heat.isLidClosed == true, heat.isHot else {
            hotSince = nil
            return false
        }
        let since = hotSince ?? uptime
        hotSince = since
        return uptime - since >= Self.sustained
    }
}
