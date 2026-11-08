import Foundation

public enum UsageAggregator {
    /// Totals for today, the last 7 days (today plus the 6 days before), this
    /// calendar month and all time, in the calendar's time zone.
    public static func summarize(_ days: DailyUsage, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let dayKey = DayKey(calendar: calendar)
        let todayKey = dayKey.key(for: now)
        let monthPrefix = dayKey.monthPrefix(for: now)
        let startOfToday = calendar.startOfDay(for: now)
        let last7Keys = Set((0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: startOfToday).map(dayKey.key(for:))
        })

        var summary = UsageSummary()
        var models: [String: TokenCounts] = [:]

        for (day, perModel) in days {
            let dayTotal = perModel.values.reduce(TokenCounts.zero, +)
            summary.allTime.add(dayTotal)
            if day == todayKey { summary.today.add(dayTotal) }
            if day.hasPrefix(monthPrefix) { summary.thisMonth.add(dayTotal) }
            if last7Keys.contains(day) {
                summary.last7Days.add(dayTotal)
                // Grouped by display name, so e.g. "claude-sonnet-4-5" and its dated
                // "claude-sonnet-4-5-20250929" form a single "Sonnet 4.5" row.
                for (model, tokens) in perModel { models[Format.modelName(model), default: .zero].add(tokens) }
            }
        }

        summary.modelsLast7Days = models
            .map { ModelUsage(model: $0.key, tokens: $0.value) }
            // Ranked by the headline number (cache reads would just rank the longest
            // conversations first). Ties broken by name: dictionary order is random, and the
            // list shouldn't reshuffle on refresh.
            .sorted { ($0.tokens.excludingCacheReads, $1.model) > ($1.tokens.excludingCacheReads, $0.model) }
        return summary
    }
}
