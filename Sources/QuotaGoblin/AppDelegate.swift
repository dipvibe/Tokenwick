import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    /// Exists only while the panel is open (see popoverDidClose).
    private var popover: NSPopover?
    private let model = UsageModel()
    private var wakeObserver: NSObjectProtocol?
    private var lastPopoverClose: Date?
    private var appToRestore: NSRunningApplication?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would show two icons and race on the cache file.
        if Self.anotherInstanceIsRunning() {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.load()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Quota Goblin"
            // The tooltip is built when the pointer arrives, not on a timer.
            button.addTrackingArea(NSTrackingArea(rect: .zero,
                                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil))
        }

        model.onChange = { [weak self] in self?.updateStatusItem() }
        model.start()
        updateStatusItem()

        // `kill` / `pkill` (used by the installer) skip applicationWillTerminate. Catch
        // SIGTERM so unsaved scan progress is written before quitting.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.model.flushToDisk() }
            exit(0)
        }
        source.resume()
        terminationSource = source

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5)) // let the network come back first
                self?.model.handleWake()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushToDisk()
    }

    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false } // unbundled dev build
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    // MARK: Panel

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
        } else if let closedAt = lastPopoverClose, Date().timeIntervalSince(closedAt) < 0.3 {
            // A transient popover closes on mouse-down when you click the icon, and the
            // icon's action then fires on mouse-up and would reopen it. Treat it as "close".
            return
        } else if let button = statusItem.button {
            // Remember who had focus, to hand it back when the panel closes.
            let front = NSWorkspace.shared.frontmostApplication
            appToRestore = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            model.refreshForPanel()
            // Built fresh on each open (in milliseconds) and released on close, so nothing
            // is laid out, redrawn or kept in memory while the panel is closed.
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            let hosting = NSHostingController(rootView: PopoverView(model: model))
            hosting.sizingOptions = .preferredContentSize
            popover.contentViewController = hosting
            self.popover = popover
            // A hidden app's windows stay invisible (see popoverDidClose, which may hide it).
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    // MARK: Menu bar

    /// Updates the optional "23% · 41%" text. Called only when limits or settings change.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        var title = ""
        if model.showPercentInMenuBar, let limits = model.limits {
            let now = Date()
            let parts = [limits.session, limits.weekly]
                .compactMap { $0 }
                .filter { !$0.hasReset(at: now) } // a past reset makes the % meaningless
                .map { "\(Int($0.percentUsed.rounded()))%" }
            if !parts.isEmpty { title = " " + parts.joined(separator: " · ") }
        }
        if button.title != title { button.title = title }
    }

    // MARK: Tooltip (built on hover)

    @objc func mouseEntered(with event: NSEvent) {
        statusItem?.button?.toolTip = tooltipText()
        model.refreshForTooltip() // anything stale is refreshed for next time
    }

    @objc func mouseExited(with event: NSEvent) {}

    private func tooltipText() -> String {
        let now = Date()
        var lines = ["Quota Goblin"]
        if model.limitsEnabled {
            if let limits = model.limits {
                if let session = limits.session { lines.append(Self.describe("Session (5h)", session, now: now)) }
                if let weekly = limits.weekly { lines.append(Self.describe("Weekly", weekly, now: now)) }
                if let extra = limits.extra { lines.append(Self.describe(extra)) }
                if let error = model.limitsError { lines.append("⚠︎ \(error)") }
            } else {
                lines.append(model.limitsError ?? "Limits: loading…")
            }
        }
        let s = UsageAggregator.summarize(model.days, now: now, calendar: .autoupdatingCurrent)
        // Input + output + cache writes; cache reads are cheap and would inflate the numbers.
        lines.append("Today: \(Format.tokens(s.today.excludingCacheReads)) tokens")
        lines.append("Last 7 days: \(Format.tokens(s.last7Days.excludingCacheReads))")
        lines.append("This month: \(Format.tokens(s.thisMonth.excludingCacheReads))")
        lines.append("All time: \(Format.tokens(s.allTime.excludingCacheReads))")
        lines.append("(+ \(Format.tokens(s.today.cacheRead)) cache reads today)")
        return lines.joined(separator: "\n")
    }

    private static func describe(_ extra: ExtraUsage) -> String {
        guard extra.isEnabled else {
            // Money spent earlier this month still counts after switching it off.
            if let used = extra.used, used.amount > 0 { return "Extra usage: off (\(Format.money(used)) spent this month)" }
            return "Extra usage: off"
        }
        var line = "Extra usage: " + (extra.used.map { "\(Format.money($0)) spent" } ?? "on")
        if let limit = extra.limit { line += " of \(Format.money(limit))" }
        if extra.limitReached { line += " (limit reached)" }
        return line
    }

    private static func describe(_ name: String, _ window: LimitWindow, now: Date) -> String {
        if window.hasReset(at: now) { return "\(name): reset, refreshing…" }
        var line = "\(name): \(Int(window.percentUsed.rounded()))% used"
        if let reset = window.resetsAt {
            line += ", resets \(Format.resetTime(reset)) (\(Format.countdown(to: reset, from: now)))"
        }
        return line
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        // Release the panel: its SwiftUI views and its window, including the window's
        // backing surface (about 3 MB). Deferred because the popover is still delivering
        // this notification. The identity check skips it if a new panel was opened since.
        let closed = notification.object as? NSPopover
        DispatchQueue.main.async { [weak self] in
            guard let self, let closed, self.popover === closed else { return }
            closed.contentViewController = nil
            self.popover = nil
            // Give the memory the panel used back to macOS now, rather than whenever.
            malloc_zone_pressure_relief(nil, 0)
        }

        // Hand focus back. Left active with no windows, this app would keep the menu bar
        // visible over full-screen apps, which isn't how macOS normally behaves. (If you
        // closed the panel by clicking another app, that app is already active: nothing to do.)
        if NSApp.isActive {
            if let app = appToRestore, !app.isTerminated {
                app.activate()
            } else {
                NSApp.hide(nil) // activates the next app in line
            }
        }
        appToRestore = nil
    }
}
