import Foundation

/// Token counts for one or more Claude responses.
public struct TokenCounts: Codable, Equatable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    /// Saturating sums throughout: Swift traps on integer overflow, so huge values from a
    /// corrupted or malicious log must clamp, not crash (a crash would repeat on every launch).
    public var total: Int {
        Self.saturatingAdd(Self.saturatingAdd(input, output), Self.saturatingAdd(cacheWrite, cacheRead))
    }

    /// Input + output + cache writes: every token processed at full price or more (cache
    /// writes cost 1.25× input). This is the headline number. Cache reads, re-reading the
    /// conversation so far, are left out: they cost about a tenth as much, count far less
    /// toward plan limits, and are usually over 90% of `total`, which would make usage look
    /// dozens of times bigger than it is.
    public var excludingCacheReads: Int {
        Self.saturatingAdd(Self.saturatingAdd(input, output), cacheWrite)
    }

    public mutating func add(_ other: TokenCounts) {
        input = Self.saturatingAdd(input, other.input)
        output = Self.saturatingAdd(output, other.output)
        cacheWrite = Self.saturatingAdd(cacheWrite, other.cacheWrite)
        cacheRead = Self.saturatingAdd(cacheRead, other.cacheRead)
    }

    static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? .max : .min) : sum
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        var result = lhs
        result.add(rhs)
        return result
    }
}

/// Usage per local calendar day ("yyyy-MM-dd") and per model.
public typealias DailyUsage = [String: [String: TokenCounts]]

public struct ModelUsage: Equatable, Sendable, Identifiable {
    public var id: String { model }
    /// Display name, e.g. "Opus 5.5" (see `Format.modelName`).
    public let model: String
    public let tokens: TokenCounts

    public init(model: String, tokens: TokenCounts) {
        self.model = model
        self.tokens = tokens
    }
}

public struct UsageSummary: Equatable, Sendable {
    public var today: TokenCounts
    public var last7Days: TokenCounts
    public var thisMonth: TokenCounts
    public var allTime: TokenCounts
    /// Models used in the last 7 days, biggest first (by `excludingCacheReads`).
    public var modelsLast7Days: [ModelUsage]

    public init(today: TokenCounts = .zero, last7Days: TokenCounts = .zero, thisMonth: TokenCounts = .zero,
                allTime: TokenCounts = .zero, modelsLast7Days: [ModelUsage] = []) {
        self.today = today
        self.last7Days = last7Days
        self.thisMonth = thisMonth
        self.allTime = allTime
        self.modelsLast7Days = modelsLast7Days
    }

    public static let empty = UsageSummary()
}

/// One rate-limit window (the 5-hour session or the 7-day week).
public struct LimitWindow: Equatable, Sendable {
    /// Normally 0–100. Always finite and within 0...1000, so `Int(percentUsed)` can't trap.
    public let percentUsed: Double
    /// Nil when the window hasn't started (e.g. no session in the last 5 hours).
    public let resetsAt: Date?

    public init(percentUsed: Double, resetsAt: Date?) {
        // Clamped here, not just in the parser, so every LimitWindow is safe to display.
        self.percentUsed = percentUsed.isFinite ? min(max(percentUsed, 0), 1_000) : 0
        self.resetsAt = resetsAt
    }

    /// True once the reset time has passed, which makes `percentUsed` out of date.
    public func hasReset(at now: Date = Date()) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

/// An amount of money, e.g. $12.34.
public struct Money: Equatable, Sendable {
    /// In whole units (dollars, not cents). Always finite and within ±1 trillion.
    public let amount: Double
    /// ISO 4217 code such as "USD", if the server gave one.
    public let currency: String?

    public init(amount: Double, currency: String?) {
        self.amount = amount.isFinite ? min(max(amount, -1e12), 1e12) : 0
        self.currency = currency
    }
}

/// Extra usage: pay-as-you-go credit that keeps Claude working after you reach your plan
/// limits, up to a monthly spending limit you choose.
public struct ExtraUsage: Equatable, Sendable {
    public let isEnabled: Bool
    /// Spent so far this month.
    public let used: Money?
    /// Your monthly spending limit. Nil if there isn't one or the server didn't say.
    public let limit: Money?
    /// Prepaid credit left, if any was bought.
    public let balance: Money?
    /// Share of the monthly limit used, normally 0–100. Clamped to 0...1000.
    public let percentUsed: Double?
    public let limitReached: Bool
    /// Switched off by the user, rather than unavailable for the account.
    public let turnedOffByUser: Bool

    public init(isEnabled: Bool, used: Money? = nil, limit: Money? = nil, balance: Money? = nil,
                percentUsed: Double? = nil, limitReached: Bool = false, turnedOffByUser: Bool = false) {
        self.isEnabled = isEnabled
        self.used = used
        self.limit = limit
        self.balance = balance
        self.percentUsed = percentUsed.map { $0.isFinite ? min(max($0, 0), 1_000) : 0 }
        self.limitReached = limitReached
        self.turnedOffByUser = turnedOffByUser
    }
}

/// The plan limits reported by Anthropic. Any part may be missing.
public struct PlanLimits: Equatable, Sendable {
    public let session: LimitWindow?
    public let weekly: LimitWindow?
    public let extra: ExtraUsage?

    public init(session: LimitWindow?, weekly: LimitWindow?, extra: ExtraUsage? = nil) {
        self.session = session
        self.weekly = weekly
        self.extra = extra
    }

    public func anyWindowHasReset(at now: Date = Date()) -> Bool {
        [session, weekly].contains { $0?.hasReset(at: now) ?? false }
    }
}
