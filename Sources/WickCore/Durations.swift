import Foundation

public let wickVersion = "0.3.0"

public enum Durations {
    /// Accepts `90`, `90m`, `2h`, `1h30m` and `45s`. A bare number means minutes.
    public static func parse(_ text: String) -> TimeInterval? {
        let text = text.lowercased()
        if let minutes = Double(text) { return minutes > 0 ? minutes * 60 : nil }

        var total: TimeInterval = 0
        var remainder = Substring(text)
        while let match = remainder.prefixMatch(of: /(\d+)(h|m|s)/) {
            let unit: TimeInterval = switch match.2 {
            case "h": 3600
            case "m": 60
            default: 1
            }
            total += (Double(match.1) ?? 0) * unit
            remainder = remainder[match.range.upperBound...]
        }
        return remainder.isEmpty && total > 0 ? total : nil
    }

    /// `1:42:09`, or `42:09` under an hour. Stable-width enough for a countdown.
    public static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let (hours, minutes, rest) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// `2h 05m`, `42m` or `<1m`. For the menu bar, where a ticking second would pull the eye.
    public static func compact(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.up))
        if interval < 60 { return "<1m" }
        return minutes >= 60
            ? String(format: "%dh %02dm", minutes / 60, minutes % 60)
            : "\(minutes)m"
    }
}
