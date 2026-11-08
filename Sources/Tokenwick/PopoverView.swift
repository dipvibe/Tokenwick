import AppKit
import SwiftUI
import UsageCore

struct PopoverView: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        // Re-renders once a minute while the panel is open (countdowns, "today" after
        // midnight). The view only exists while open, so this costs nothing otherwise.
        TimelineView(.everyMinute) { context in
            let summary = UsageAggregator.summarize(model.days, now: context.date, calendar: .autoupdatingCurrent)
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.limitsEnabled {
                    LimitsSection(limits: model.limits, error: model.limitsError,
                                  fetchedAt: model.limitsFetchedAt, now: context.date)
                    Divider()
                }
                TokenSection(summary: summary,
                             showEmptyHint: model.hasScanned && summary.allTime.total == 0)
                if !summary.modelsLast7Days.isEmpty {
                    Divider()
                    ModelSection(models: summary.modelsLast7Days)
                }
                Divider()
                SettingsSection(model: model)
                footer
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = MenuBarIcon.custom {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: 18, height: 18)
            } else {
                Image(systemName: "sparkle").foregroundStyle(.orange)
            }
            Text("Tokenwick").font(.headline)
            Spacer()
            if !model.hasScanned { ProgressView().controlSize(.small) } // first scan only, no flicker later
            Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh now")
        }
    }

    private var footer: some View {
        HStack {
            if let updated = model.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
    }
}

private struct LimitsSection: View {
    let limits: PlanLimits?
    let error: String?
    let fetchedAt: Date?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let limits {
                if let session = limits.session {
                    LimitRow(title: "Current session (5h)", window: session, now: now,
                             idleText: "No active session. It starts with your next message.")
                }
                if let weekly = limits.weekly {
                    LimitRow(title: "Weekly limit", window: weekly, now: now, idleText: nil)
                }
                if let extra = limits.extra {
                    ExtraUsageRow(extra: extra)
                }
                if let error {
                    // Last good numbers stay visible; say why they may be out of date.
                    warning(staleText(error))
                }
            } else if let error {
                SectionTitle("Plan limits")
                warning(error)
            } else {
                SectionTitle("Plan limits")
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func staleText(_ error: String) -> String {
        guard let fetchedAt else { return error }
        return "\(error) Showing data from \(fetchedAt.formatted(date: .omitted, time: .shortened))."
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LimitRow: View {
    let title: String
    let window: LimitWindow
    let now: Date
    /// Shown instead of a reset time when the window hasn't started.
    let idleText: String?

    var body: some View {
        // After the reset time the old % no longer applies; a refresh is already on its way.
        let hasReset = window.hasReset(at: now)
        let percent = hasReset ? 0 : window.percentUsed
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title)
                Spacer()
                Text(hasReset ? "–" : "\(Int(percent.rounded()))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("used").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(color(for: percent))
            if hasReset {
                Text("Just reset. Refreshing…").font(.caption).foregroundStyle(.secondary)
            } else if let reset = window.resetsAt {
                Text("Resets \(Format.countdown(to: reset, from: now)) · \(Format.resetTime(reset))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let idleText {
                Text(idleText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(for percent: Double) -> Color {
        percent >= 90 ? .red : (percent >= 70 ? .orange : .green)
    }
}

/// Extra usage: pay-as-you-go credit used after the plan limits run out.
private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Extra usage")
                Spacer()
                if extra.isEnabled, let used = extra.used {
                    Text(Format.money(used))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("spent").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(extra.isEnabled ? "On" : "Off").font(.callout).foregroundStyle(.secondary)
                }
            }
            if extra.isEnabled {
                if let percent = extra.percentUsed, extra.limit != nil {
                    ProgressView(value: min(max(percent, 0), 100), total: 100)
                        .tint(percent >= 90 ? .red : (percent >= 70 ? .orange : .green))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(extra.limitReached ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(offText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("Extra usage keeps Claude working after you reach your plan limits, billed as you go up to a monthly limit you set.")
    }

    /// Mentions money already spent this month, which still counts after switching it off.
    private var offText: String {
        var text = extra.turnedOffByUser ? "Turned off in your Claude settings." : "Not enabled for this account."
        if let used = extra.used, used.amount > 0 { text += " \(Format.money(used)) spent this month." }
        return text
    }

    private var detail: String {
        var parts: [String] = []
        if extra.limitReached {
            parts.append("Monthly limit reached")
        } else if let limit = extra.limit {
            parts.append("of \(Format.money(limit)) monthly limit")
        } else {
            parts.append("This month")
        }
        if let balance = extra.balance { parts.append("Balance \(Format.money(balance))") }
        return parts.joined(separator: " · ")
    }
}

private struct TokenSection: View {
    let summary: UsageSummary
    /// True after a scan found no Claude Code usage at all (e.g. a brand-new install).
    let showEmptyHint: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Claude Code tokens")
                .help("Input + output + cache writes. Cache reads are listed separately: they're cheap and count much less toward your limits.")
            if showEmptyHint {
                Label("No Claude Code usage found yet. Use Claude Code in your terminal and it will show up here within a minute.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row("Today", summary.today)
            row("Last 7 days", summary.last7Days)
            row("This month", summary.thisMonth)
            row("All time", summary.allTime)
        }
    }

    private func row(_ label: String, _ tokens: TokenCounts) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                Spacer()
                // Input + output + cache writes. Cache reads are cheap and usually over 90% of
                // the raw total, so they get their own line instead of inflating this number.
                Text(Format.tokens(tokens.excludingCacheReads)).fontWeight(.semibold).monospacedDigit()
            }
            Text("in \(Format.tokens(tokens.input)) · out \(Format.tokens(tokens.output)) · cache write \(Format.tokens(tokens.cacheWrite))")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            Text("+ \(Format.tokens(tokens.cacheRead)) cache reads")
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                .lineLimit(1)
        }
        .help("\(tokens.excludingCacheReads.formatted()) tokens, plus \(tokens.cacheRead.formatted()) cache reads")
    }
}

private struct ModelSection: View {
    let models: [ModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Models, last 7 days")
            ForEach(models.prefix(5)) { item in
                HStack {
                    Text(item.model).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    // `item.model` is already a display name ("Opus 5.5"), see Format.modelName.
                    Text(Format.tokens(item.tokens.excludingCacheReads)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SettingsSection: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show session · weekly % in menu bar", isOn: $model.showPercentInMenuBar)
            Toggle("Fetch plan limits (unofficial API)", isOn: $model.limitsEnabled)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
