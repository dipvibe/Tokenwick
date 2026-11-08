import Foundation

/// Converts dates to "yyyy-MM-dd" keys in a given calendar's time zone.
struct DayKey {
    let calendar: Calendar
    private let formatter: DateFormatter

    init(calendar: Calendar) {
        self.calendar = calendar
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        formatter = f
    }

    func key(for date: Date) -> String { formatter.string(from: date) }

    /// "yyyy-MM" prefix shared by every day in the month containing `date`.
    func monthPrefix(for date: Date) -> String { String(key(for: date).prefix(7)) }
}

enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
