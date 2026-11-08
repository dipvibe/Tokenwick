import Foundation
import ServiceManagement
import UsageCore

/// App state. Designed to do no work while idle:
/// - Logs are read when FSEvents reports a change (no polling).
/// - Summaries (today, 7 days, …) are computed only when shown, so nothing runs at midnight.
/// - Limits refresh on a timer only while their % is shown in the menu bar. Otherwise they
///   refresh when you look (panel or tooltip), and once right after each reset.
@MainActor
final class UsageModel: ObservableObject {
    // MARK: Token usage (local logs)

    /// Totals per local day and model.
    @Published private(set) var days: DailyUsage = [:]
    @Published private(set) var hasScanned = false
    @Published private(set) var lastUpdated: Date?

    // MARK: Plan limits (unofficial endpoint)

    /// The last limits fetched successfully. Kept when a later refresh fails, so a
    /// network blip doesn't empty the panel; `limitsError` then explains why it's stale.
    @Published private(set) var limits: PlanLimits?
    @Published private(set) var limitsFetchedAt: Date?
    @Published private(set) var limitsError: String?

    // MARK: Settings

    @Published var showPercentInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showPercentInMenuBar, forKey: Keys.showPercent)
            if showPercentInMenuBar { refreshLimits() }
            scheduleLimitRefreshes()
            onChange?()
        }
    }

    @Published var limitsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(limitsEnabled, forKey: Keys.limitsEnabled)
            cancelLimitsFetch()
            limits = nil
            limitsFetchedAt = nil
            limitsError = nil
            lastLimitsAttempt = nil
            if limitsEnabled { refreshLimits(minimumInterval: 0) }
            scheduleLimitRefreshes()
            onChange?()
        }
    }

    /// Only works when running from the bundled .app (see scripts/bundle.sh).
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// Called whenever something shown in the menu bar itself changes.
    var onChange: (() -> Void)?

    private enum Keys {
        static let showPercent = "showPercentInMenuBar"
        static let limitsEnabled = "planLimitsEnabled"
    }

    // Log scanning runs at background QoS (efficiency cores on Apple silicon). A scan the
    // user is waiting for is boosted per work item.
    private let scanner = LogScanner()
    private let scanQueue = DispatchQueue(label: "QuotaGoblin.scan", qos: .background,
                                          autoreleaseFrequency: .workItem)
    private var watcher: LogWatcher?
    private var watchedDirectories: [URL] = []
    private var lastFullScan = Date.distantPast
    /// A full rescan when you look, at most this often. FSEvents covers everything in between.
    private static let fullScanInterval: TimeInterval = 10 * 60

    private let client = PlanLimitsClient()
    private var limitsTask: Task<Void, Never>?
    private var lastLimitsAttempt: Date?
    /// Bumped to invalidate an in-flight fetch, so a stale result is never applied.
    private var limitsGeneration = 0
    private var periodicLimitsTimer: Timer?
    private var resetTimer: Timer?
    private var syncingLoginItem = false

    init() {
        let defaults = UserDefaults.standard
        // Icon only by default; the % text can be turned on in the panel.
        defaults.register(defaults: [Keys.showPercent: false, Keys.limitsEnabled: true])
        showPercentInMenuBar = defaults.bool(forKey: Keys.showPercent)
        limitsEnabled = defaults.bool(forKey: Keys.limitsEnabled)
        launchAtLogin = Self.loginItemEnabled
    }

    // MARK: Lifecycle

    func start() {
        fullScan(qos: .utility)
        refreshLimits(minimumInterval: 0)
        scheduleLimitRefreshes()
    }

    /// The panel is opening: make sure what it shows is current.
    func refreshForPanel() {
        syncLaunchAtLogin()
        if Date().timeIntervalSince(lastFullScan) > Self.fullScanInterval { fullScan(qos: .userInitiated) }
        refreshLimits(minimumInterval: 60)
    }

    /// The pointer is over the icon. The tooltip shows what we have now; anything
    /// stale is refreshed in the background for next time.
    func refreshForTooltip() {
        if Date().timeIntervalSince(lastFullScan) > Self.fullScanInterval { fullScan(qos: .utility) }
        refreshLimits(minimumInterval: 5 * 60)
    }

    /// The manual refresh button.
    func refreshNow() {
        fullScan(qos: .userInitiated)
        refreshLimits(minimumInterval: 10)
    }

    func handleWake() {
        // Only the menu bar % needs to be fresh without anyone looking.
        if showPercentInMenuBar { refreshLimits(minimumInterval: 0) }
    }

    /// Saves unsaved scan progress. Call before quitting.
    func flushToDisk() {
        let scanner = self.scanner
        scanQueue.sync { scanner.flush() }
    }

    // MARK: Logs

    private func fullScan(qos: DispatchQoS) {
        lastFullScan = Date()
        let scanner = self.scanner
        scanQueue.async(qos: qos, flags: .enforceQoS) { [weak self] in
            let days = scanner.scan()
            let directories = scanner.directoriesToWatch()
            // A full scan (at launch, or at most every 10 minutes) churns through read
            // buffers. Return the freed memory to macOS instead of keeping it reserved.
            malloc_zone_pressure_relief(nil, 0)
            Task { @MainActor in
                guard let self else { return }
                self.apply(days)
                self.watch(directories)
            }
        }
    }

    /// (Re)starts FSEvents on the log folders. A no-op if they haven't changed.
    private func watch(_ directories: [URL]) {
        guard directories != watchedDirectories else { return }
        watchedDirectories = directories
        let scanner = self.scanner
        let old = watcher
        // 10 s latency batches Claude Code's rapid writes into one small read.
        watcher = LogWatcher(directories: directories, latency: 10, queue: scanQueue) { [weak self] paths, needsFullScan in
            let days = needsFullScan ? scanner.scan() : scanner.scan(changedPaths: paths)
            Task { @MainActor in self?.apply(days) }
        }
        // Release the old watcher on its own queue: an event for it may already be queued
        // there, and freeing it here first would leave that event pointing at freed memory.
        if let old { scanQueue.async { withExtendedLifetime(old) {} } }
    }

    private func apply(_ newDays: DailyUsage) {
        if days != newDays { days = newDays }
        if !hasScanned { hasScanned = true }
        lastUpdated = Date()
    }

    // MARK: Limits

    func refreshLimits(minimumInterval: TimeInterval = 60) {
        guard limitsEnabled, limitsTask == nil else { return }
        let now = Date()
        if let last = lastLimitsAttempt, now.timeIntervalSince(last) < minimumInterval { return }
        lastLimitsAttempt = now

        limitsGeneration += 1
        let generation = limitsGeneration
        let client = self.client
        limitsTask = Task { [weak self] in
            let result = await client.fetch()
            guard let self, generation == self.limitsGeneration else { return }
            self.limitsTask = nil
            switch result {
            case .success(let value):
                self.limits = value
                self.limitsFetchedAt = Date()
                self.limitsError = nil
            case .failure(let error):
                self.limitsError = error.message
            }
            self.scheduleLimitRefreshes()
            self.onChange?()
        }
    }

    /// - Every 5 minutes, only while the % is shown in the menu bar.
    /// - Once, just after the next session or weekly reset, so a new window shows promptly.
    private func scheduleLimitRefreshes() {
        if limitsEnabled && showPercentInMenuBar {
            if periodicLimitsTimer == nil {
                periodicLimitsTimer = makeTimer(after: 300, repeats: true) { $0.refreshLimits(minimumInterval: 0) }
            }
        } else {
            periodicLimitsTimer?.invalidate()
            periodicLimitsTimer = nil
        }

        resetTimer?.invalidate()
        resetTimer = nil
        let now = Date()
        let nextReset = [limits?.session?.resetsAt, limits?.weekly?.resetsAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
        if limitsEnabled, let nextReset {
            resetTimer = makeTimer(after: nextReset.timeIntervalSince(now) + 5, repeats: false) {
                $0.refreshLimits(minimumInterval: 0)
            }
        }
    }

    private func makeTimer(after interval: TimeInterval, repeats: Bool,
                           _ action: @escaping @MainActor (UsageModel) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        timer.tolerance = min(max(interval / 10, 1), 60) // lets macOS batch wake-ups
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func cancelLimitsFetch() {
        limitsGeneration += 1
        limitsTask?.cancel()
        limitsTask = nil
    }

    // MARK: Launch at login

    private static var loginItemEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Picks up changes made in System Settings while the app was running.
    func syncLaunchAtLogin() {
        syncingLoginItem = true
        defer { syncingLoginItem = false }
        let enabled = Self.loginItemEnabled
        if launchAtLogin != enabled { launchAtLogin = enabled }
    }

    private func applyLaunchAtLogin() {
        guard !syncingLoginItem, launchAtLogin != Self.loginItemEnabled else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Fall through: the toggle snaps back to the real state below.
        }
        syncLaunchAtLogin()
    }
}
