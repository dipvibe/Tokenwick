import AppKit
import UsageCore

// `QuotaGoblin --status` prints your plan limits as JSON and exits, for scripts and
// AI agents (e.g. to pause work when the session is nearly used up). It never prints
// the login token, only percentages, reset times and extra-usage amounts.
if CommandLine.arguments.contains("--status") {
    exit(StatusCommand.run())
}

// Before AppDelegate creates the model, which reads settings and the cache.
LegacyMigration.run()

// Top-level code runs on the main thread. `NSApplication.delegate` is weak, so keep a strong reference here.
let delegate = MainActor.assumeIsolated { AppDelegate() }
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()

enum StatusCommand {
    private final class Box: @unchecked Sendable {
        var result: Result<PlanLimits, PlanLimitsError> = .failure(.network)
    }

    static func run() -> Int32 {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.result = await PlanLimitsClient().fetch()
            done.signal()
        }
        done.wait()

        var output: [String: Any] = [:]
        switch box.result {
        case .success(let limits):
            output["session"] = limits.session.map(describe) ?? NSNull()
            output["weekly"] = limits.weekly.map(describe) ?? NSNull()
            output["extra_usage"] = limits.extra.map(describe) ?? NSNull()
        case .failure(let error):
            output["error"] = error.message
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        if case .success = box.result { return 0 }
        return 1
    }

    /// e.g. {"enabled": true, "used": 12.34, "limit": 50, "currency": "USD", "percent_used": 24.7, "limit_reached": false}
    private static func describe(_ extra: ExtraUsage) -> [String: Any] {
        var info: [String: Any] = ["enabled": extra.isEnabled, "limit_reached": extra.limitReached]
        if let used = extra.used { info["used"] = used.amount }
        if let limit = extra.limit { info["limit"] = limit.amount }
        if let balance = extra.balance { info["balance"] = balance.amount }
        if let currency = extra.used?.currency ?? extra.limit?.currency { info["currency"] = currency }
        if let percent = extra.percentUsed { info["percent_used"] = percent }
        return info
    }

    private static func describe(_ window: LimitWindow) -> [String: Any] {
        [
            "percent_used": window.percentUsed,
            "resets_at": window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
        ]
    }
}
