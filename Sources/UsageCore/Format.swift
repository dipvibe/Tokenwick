import Foundation

public enum Format {
    private static let units: [(size: Double, suffix: String)] = [(1e3, "K"), (1e6, "M"), (1e9, "B"), (1e12, "T")]

    /// 950 → "950", 12_300 → "12.3K", 4_560_000 → "4.56M", 999_950 → "1M", 1_200_000_000 → "1.2B".
    public static func tokens(_ value: Int) -> String {
        let v = Double(value)
        guard var index = units.lastIndex(where: { abs(v) >= $0.size }) else { return String(value) }
        while true {
            let text = trimmed(v / units[index].size)
            // Rounding can reach 1000 (999_950 → "1000K"): move up a unit instead.
            if let shown = Double(text), abs(shown) >= 1000, index + 1 < units.count {
                index += 1
                continue
            }
            return text + units[index].suffix
        }
    }

    /// Three significant digits, without trailing zeros. `String(format:)` always uses "." here.
    private static func trimmed(_ x: Double) -> String {
        let digits = abs(x) >= 100 ? 0 : (abs(x) >= 10 ? 1 : 2)
        var text = String(format: "%.\(digits)f", x)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// Time until `date`, e.g. "in 2d 4h", "in 3h 12m", "in 5m".
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite, interval > 0 else { return "now" }
        // Clamp before converting: Int(Double) traps when the value doesn't fit.
        let seconds = Int(min(interval, 100 * 365 * 86_400))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(max(minutes, 1))m"
    }

    /// e.g. "Tue 9:00 PM", in the current locale and time zone.
    public static func resetTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "$12.34", in the user's locale. Without a currency code, just the number ("12.34").
    public static func money(_ money: Money, locale: Locale = .autoupdatingCurrent) -> String {
        if let code = money.currency {
            return money.amount.formatted(.currency(code: code).locale(locale))
        }
        return money.amount.formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// Readable model names:
    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5",
    /// "claude-3-5-haiku-20241022" → "Haiku 3.5", "claude-sonnet-4-5[1m]" → "Sonnet 4.5 (1M)".
    /// Anything else (a new naming scheme, "unknown") is shown as logged.
    public static func modelName(_ raw: String) -> String {
        var name = raw.lowercased()
        var suffix = ""
        if name.hasSuffix("[1m]") {   // the 1-million-token context variant
            name.removeLast(4)
            suffix = " (1M)"
        }
        guard name.hasPrefix("claude-") else { return raw }
        var parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // A trailing release date, e.g. 20250929.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isASCIIDigit) { parts.removeLast() }
        // Exactly one family word ("opus") and one or more short version numbers, in either
        // order: "opus-5-5" (current scheme) or "3-5-haiku" (older one).
        let words = parts.filter { !$0.allSatisfy(\.isASCIIDigit) }
        let numbers = parts.filter { $0.allSatisfy(\.isASCIIDigit) }
        guard words.count == 1, let family = words.first, family.allSatisfy(\.isLetter),
              !numbers.isEmpty, numbers.allSatisfy({ (1...2).contains($0.count) }) else { return raw }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + numbers.joined(separator: ".") + suffix
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
