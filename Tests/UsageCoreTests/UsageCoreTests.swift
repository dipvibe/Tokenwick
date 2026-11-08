import Foundation
import Testing
@testable import UsageCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func assistantLine(id: String, request: String, time: String, model: String = "claude-opus-5-5",
                           input: Int = 10, output: Int = 20, cacheWrite: Int = 30, cacheRead: Int = 40) -> String {
    """
    {"type":"assistant","timestamp":"\(time)","requestId":"\(request)","uuid":"u-\(id)","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
    """
}

/// A throwaway `projects` folder with one project, removed when the test ends.
private final class TempProjects {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("cub-\(UUID().uuidString)")
    var root: URL { base.appendingPathComponent("projects") }
    var project: URL { root.appendingPathComponent("-Users-test") }
    var cache: URL { base.appendingPathComponent("cache.plist") }

    init() throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func file(_ name: String = "session.jsonl") -> URL { project.appendingPathComponent(name) }

    func scanner(chunkSize: Int = 1 << 20, maxLineLength: Int = 32 << 20, saveInterval: TimeInterval = 0) -> LogScanner {
        LogScanner(roots: [root], cacheURL: cache, calendar: utc, chunkSize: chunkSize,
                   maxLineLength: maxLineLength, saveInterval: saveInterval)
    }

    func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

@Suite struct LogScannerTests {
    @Test func countsAssistantUsageAndSkipsNoise() throws {
        let t = try TempProjects()
        let lines = [
            assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00.000Z"),
            assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:01.000Z"), // same response, second line
            assistantLine(id: "m2", request: "r2", time: "2026-11-07T11:00:00Z", model: "<synthetic>"),
            #"{"type":"user","timestamp":"2026-11-07T10:00:00Z","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"user","message":{"content":"the word \"usage\" and \"assistant\" in a user message"}}"#,
            "not json at all",
            assistantLine(id: "m3", request: "r3", time: "2026-11-08T00:30:00Z", model: "claude-sonnet-5-5",
                          input: 1, output: 2, cacheWrite: 0, cacheRead: 0),
        ]
        try t.append(lines.joined(separator: "\n") + "\n", to: t.file())

        let days = t.scanner().scan()
        #expect(days["2026-11-07"]?["claude-opus-5-5"] == TokenCounts(input: 10, output: 20, cacheWrite: 30, cacheRead: 40))
        #expect(days["2026-11-07"]?["<synthetic>"] == nil)
        #expect(days["2026-11-08"]?["claude-sonnet-5-5"]?.total == 3)
    }

    @Test func readsIncrementallyAndWaitsForPartialLines() throws {
        let t = try TempProjects()
        let scanner = t.scanner()
        let line = assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z")

        try t.append(String(line.prefix(40)), to: t.file()) // still being written
        #expect(scanner.scan().isEmpty)

        try t.append(String(line.dropFirst(40)) + "\n", to: t.file())
        #expect(scanner.scan()["2026-11-07"]?["claude-opus-5-5"]?.total == 100)

        try t.append(assistantLine(id: "m2", request: "r2", time: "2026-11-07T12:00:00Z") + "\n", to: t.file())
        #expect(scanner.scan()["2026-11-07"]?["claude-opus-5-5"]?.total == 200)
    }

    @Test func linesSplitAcrossReadChunks() throws {
        let t = try TempProjects()
        let lines = (1...20).map { assistantLine(id: "m\($0)", request: "r\($0)", time: "2026-11-07T10:00:00Z") }
        try t.append(lines.joined(separator: "\n") + "\n", to: t.file())
        // A 7-byte chunk splits every line many times.
        #expect(t.scanner(chunkSize: 7).scan()["2026-11-07"]?["claude-opus-5-5"]?.total == 2000)
    }

    @Test func dedupeSurvivesRestartAndSpansFiles() throws {
        let t = try TempProjects()
        let line = assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n"
        try t.append(line, to: t.file("a.jsonl"))
        _ = t.scanner().scan()

        // New process (fresh scanner, cache from disk); the same response shows up in another file.
        try t.append(line, to: t.file("b.jsonl"))
        try t.append(assistantLine(id: "m2", request: "r2", time: "2026-11-07T10:05:00Z") + "\n", to: t.file("a.jsonl"))
        #expect(t.scanner().scan()["2026-11-07"]?["claude-opus-5-5"]?.total == 200)
    }

    @Test func historySurvivesDeletedLogs() throws {
        let t = try TempProjects()
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-10-01T10:00:00Z") + "\n", to: t.file("old.jsonl"))
        let scanner = t.scanner()
        _ = scanner.scan()

        try FileManager.default.removeItem(at: t.file("old.jsonl")) // Claude Code's 30-day cleanup
        #expect(scanner.scan()["2026-10-01"]?["claude-opus-5-5"]?.total == 100)
        #expect(t.scanner().scan()["2026-10-01"]?["claude-opus-5-5"]?.total == 100)
    }

    @Test func truncatedFileIsRereadWithoutDoubleCounting() throws {
        let t = try TempProjects()
        let a = assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z")
        let b = assistantLine(id: "m2", request: "r2", time: "2026-11-07T10:01:00Z")
        try t.append(a + "\n" + b + "\n", to: t.file())
        let scanner = t.scanner()
        _ = scanner.scan()

        try Data((a + "\n").utf8).write(to: t.file()) // rewritten shorter
        #expect(scanner.scan()["2026-11-07"]?["claude-opus-5-5"]?.total == 200)
    }

    @Test func cacheFileIsPrivate() throws {
        let t = try TempProjects()
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n", to: t.file())
        _ = t.scanner().scan()
        let attrs = try FileManager.default.attributesOfItem(atPath: t.cache.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func fingerprintIsStable() {
        // Must never change between versions, or saved dedupe data stops matching.
        #expect(LogScanner.fingerprint("") == Int64(bitPattern: 0xcbf2_9ce4_8422_2325))
        #expect(LogScanner.fingerprint("a") == Int64(bitPattern: 0xaf63_dc4c_8601_ec8c))
        #expect(LogScanner.fingerprint("msg_1:req_1") != LogScanner.fingerprint("msg_1:req_2"))
    }
}

// MARK: - Hostile or corrupted input

@Suite struct HostileInputTests {
    @Test func hugeModelNamesAreCapped() throws {
        let t = try TempProjects()
        let zalgo = "a" + String(repeating: "\u{0301}", count: 50_000) // one Character, 50,001 scalars
        try t.append([
            assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z", model: String(repeating: "x", count: 100_000)),
            assistantLine(id: "m2", request: "r2", time: "2026-11-07T10:00:00Z", model: zalgo),
        ].joined(separator: "\n") + "\n", to: t.file())
        let models = try #require(t.scanner().scan()["2026-11-07"]).keys
        #expect(models.count == 2)
        #expect(models.allSatisfy { $0.unicodeScalars.count <= LogScanner.maxModelNameLength })
        #expect(LogScanner.modelName(nil) == "unknown")
        #expect(LogScanner.modelName("claude-opus-5-5") == "claude-opus-5-5")
    }

    @Test func hugeTokenCountsDontCrash() throws {
        // Before the fix, Int overflow here trapped, and the app crashed on every launch.
        let t = try TempProjects()
        let huge = Int.max
        let lines = (1...3).map {
            assistantLine(id: "m\($0)", request: "r\($0)", time: "2026-11-07T10:00:00Z",
                          input: huge, output: huge, cacheWrite: huge, cacheRead: -5)
        }
        try t.append(lines.joined(separator: "\n") + "\n", to: t.file())
        let counts = try #require(t.scanner().scan()["2026-11-07"]?["claude-opus-5-5"])
        #expect(counts.input == 3_000_000_000) // clamped to 1e9 per response
        #expect(counts.cacheRead == 0)         // negatives become 0
        #expect(counts.total > 0)
    }

    @Test func saturatingMath() {
        var a = TokenCounts(input: .max, output: .max, cacheWrite: .max, cacheRead: .max)
        a.add(TokenCounts(input: 1, output: 1, cacheWrite: 1, cacheRead: 1))
        #expect(a.input == .max)
        #expect(a.total == .max)
    }

    @Test func overlongLinesAreSkippedButLaterLinesCount() throws {
        let t = try TempProjects()
        let giant = #"{"type":"user","message":{"content":""# + String(repeating: "x", count: 5_000) + #""}}"#
        let lines = [
            assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z"),
            giant,
            assistantLine(id: "m2", request: "r2", time: "2026-11-07T10:01:00Z"),
        ]
        try t.append(lines.joined(separator: "\n") + "\n", to: t.file())
        // 1 KB line limit, read in 300-byte chunks, so the giant line spans many chunks.
        let days = t.scanner(chunkSize: 300, maxLineLength: 1_024).scan()
        #expect(days["2026-11-07"]?["claude-opus-5-5"]?.total == 200)
    }

    @Test func unfinishedOverlongLineIsSkippedOnceComplete() throws {
        let t = try TempProjects()
        let scanner = t.scanner(chunkSize: 300, maxLineLength: 1_024)
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n", to: t.file())
        try t.append(String(repeating: "y", count: 3_000), to: t.file()) // giant line, still being written
        #expect(scanner.scan()["2026-11-07"]?["claude-opus-5-5"]?.total == 100)

        try t.append("\n" + assistantLine(id: "m2", request: "r2", time: "2026-11-07T10:01:00Z") + "\n", to: t.file())
        #expect(scanner.scan()["2026-11-07"]?["claude-opus-5-5"]?.total == 200)
    }

    @Test(.timeLimit(.minutes(1))) func fifoAndSymlinkLogsAreIgnored() throws {
        let t = try TempProjects()
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n", to: t.file("real.jsonl"))
        #expect(mkfifo(t.file("trap.jsonl").path, 0o600) == 0) // opening this for reading would block forever
        try FileManager.default.createSymbolicLink(at: t.file("link.jsonl"), withDestinationURL: t.file("real.jsonl"))
        let days = t.scanner().scan() // must return, not hang
        #expect(days["2026-11-07"]?["claude-opus-5-5"]?.total == 100) // counted once, not via the symlink too
    }

    @Test(.timeLimit(.minutes(1))) func safeFileRefusesFifosAndOversizedFiles() throws {
        let t = try TempProjects()
        let fifo = t.base.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(SafeFile.read(fifo, maxBytes: 1_000) == nil) // returns immediately

        let big = t.base.appendingPathComponent("big")
        try Data(count: 2_000).write(to: big)
        #expect(SafeFile.read(big, maxBytes: 1_000) == nil)
        #expect(SafeFile.read(big, maxBytes: 2_000)?.count == 2_000)

        let empty = t.base.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(SafeFile.read(empty, maxBytes: 10) == Data())
        #expect(SafeFile.read(t.base.appendingPathComponent("missing"), maxBytes: 10) == nil)
        #expect(SafeFile.read(URL(fileURLWithPath: "/dev/zero"), maxBytes: 10) == nil) // a device, not a file
    }

    @Test func absurdServerValuesAreClamped() throws {
        let json = #"{"five_hour":{"utilization":1e300},"seven_day":{"utilization":-40,"resets_at":"9999-12-31T23:59:59Z"}}"#
        let limits = try #require(PlanLimitsClient.parseUsage(Data(json.utf8)))
        #expect(limits.session?.percentUsed == 1_000)
        #expect(limits.weekly?.percentUsed == 0)
        let far = try #require(limits.weekly?.resetsAt)
        #expect(Format.countdown(to: far).hasPrefix("in ")) // no Int(Double) trap
        #expect(Format.countdown(to: .distantFuture).hasPrefix("in "))
    }
}

// MARK: - Event-driven scanning (efficiency)

@Suite struct IncrementalScanTests {
    @Test func scansOnlyTheChangedLogFiles() throws {
        let t = try TempProjects()
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n", to: t.file("a.jsonl"))
        try t.append(assistantLine(id: "m2", request: "r2", time: "2026-11-07T10:00:00Z") + "\n", to: t.file("b.jsonl"))
        let scanner = t.scanner()
        let days = scanner.scan(changedPaths: [
            t.file("a.jsonl").path,
            t.base.appendingPathComponent("history.jsonl").path,     // outside the log folder: ignored
            t.project.appendingPathComponent("notes.txt").path,      // not a log: ignored
            t.root.appendingPathComponent(".hidden/x.jsonl").path,   // hidden folder: ignored
        ])
        #expect(days["2026-11-07"]?["claude-opus-5-5"]?.total == 100) // only a.jsonl
        #expect(scanner.trackedFileCount == 1)
    }

    @Test func eventPathsWithResolvedSymlinksMapToOneEntry() throws {
        // FSEvents reports real paths (/private/var/..., or the target of a symlinked
        // folder). They must map to the same cache entry as the directory walk.
        let t = try TempProjects()
        let link = t.base.appendingPathComponent("linked-projects")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.root)
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n", to: t.file())
        let scanner = LogScanner(roots: [link], cacheURL: t.cache, calendar: utc, chunkSize: 1 << 20)

        let realFile = URL(fileURLWithPath: t.file().resolvingSymlinksInPath().path)
        let real = String(cString: realpath(realFile.path, nil)) // e.g. /private/var/folders/...
        _ = scanner.scan(changedPaths: [real])
        let days = scanner.scan() // full walk via the symlink
        #expect(days["2026-11-07"]?["claude-opus-5-5"]?.total == 100)
        #expect(scanner.trackedFileCount == 1)
    }

    @Test func savesAreBatchedAndFlushWritesThem() throws {
        let t = try TempProjects()
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n", to: t.file())
        // Reads the saved cache without changing it (an empty incremental scan never saves).
        func onDisk() -> Int? {
            LogScanner(roots: [], cacheURL: t.cache, calendar: utc, chunkSize: 1 << 20)
                .scan(changedPaths: [])["2026-11-07"]?["claude-opus-5-5"]?.total
        }
        let scanner = t.scanner(saveInterval: 3_600)
        _ = scanner.scan() // the first save happens right away
        try t.append(assistantLine(id: "m2", request: "r2", time: "2026-11-07T10:01:00Z") + "\n", to: t.file())
        _ = scanner.scan() // within the interval: kept in memory only
        #expect(onDisk() == 100)
        scanner.flush()
        #expect(onDisk() == 200)
    }

    @Test(.timeLimit(.minutes(1))) func watcherReportsNewLogLines() async throws {
        let t = try TempProjects()
        let queue = DispatchQueue(label: "test.watcher")
        let seen = Box<[String]>([])
        let watcher = LogWatcher(directories: [t.root], latency: 0.1, queue: queue) { paths, _ in
            seen.update { $0 += paths }
        }
        #expect(watcher != nil)
        try await Task.sleep(for: .milliseconds(300)) // let FSEvents start
        try t.append(assistantLine(id: "m1", request: "r1", time: "2026-11-07T10:00:00Z") + "\n", to: t.file())
        for _ in 0..<100 where !seen.get().contains(where: { $0.hasSuffix("/session.jsonl") }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seen.get().contains { $0.hasSuffix("/session.jsonl") })
        withExtendedLifetime(watcher) {}
    }
}

@Suite struct AggregatorTests {
    @Test func periods() {
        let t = TokenCounts(input: 1)
        let days: DailyUsage = [
            "2026-11-08": ["a": t, "b": t],   // today
            "2026-11-02": ["a": t],           // 6 days ago: in last 7
            "2026-11-01": ["a": t],           // 7 days ago: not in last 7, still this month
            "2026-10-31": ["b": t],           // last month
        ]
        let now = ISODate.parse("2026-11-08T15:00:00Z")!
        let s = UsageAggregator.summarize(days, now: now, calendar: utc)
        #expect(s.today.total == 2)
        #expect(s.last7Days.total == 3)
        #expect(s.thisMonth.total == 4)
        #expect(s.allTime.total == 5)
        #expect(s.modelsLast7Days.map(\.model) == ["a", "b"])
    }

    @Test func modelsAreRankedWithoutCacheReadsAndMergedByDisplayName() {
        let days: DailyUsage = ["2026-11-08": [
            // Huge cache reads, little real work: must not outrank the model that did more.
            "claude-opus-5-5": TokenCounts(input: 10, output: 100, cacheWrite: 0, cacheRead: 9_000_000),
            "claude-sonnet-4-5": TokenCounts(output: 300),
            "claude-sonnet-4-5-20250929": TokenCounts(output: 200),
        ]]
        let s = UsageAggregator.summarize(days, now: ISODate.parse("2026-11-08T15:00:00Z")!, calendar: utc)
        #expect(s.modelsLast7Days.map(\.model) == ["Sonnet 4.5", "Opus 5.5"])
        #expect(s.modelsLast7Days.first?.tokens.output == 500)
        #expect(s.today.excludingCacheReads == 610)
        #expect(s.today.cacheRead == 9_000_000)
    }

    @Test func modelsWithEqualTotalsKeepAStableOrder() {
        // Dictionary order is random per run; ties must not reshuffle the list on every refresh.
        let t = TokenCounts(output: 5)
        let days: DailyUsage = ["2026-11-08": ["zeta": t, "alpha": t, "mid": t, "big": TokenCounts(output: 9)]]
        let now = ISODate.parse("2026-11-08T15:00:00Z")!
        for _ in 0..<20 {
            #expect(UsageAggregator.summarize(days, now: now, calendar: utc).modelsLast7Days.map(\.model)
                    == ["big", "alpha", "mid", "zeta"])
        }
    }
}

@Suite struct PlanLimitsParsingTests {
    @Test func parsesSessionAndWeekly() throws {
        let json = #"{"five_hour":{"utilization":12.0,"resets_at":"2026-11-08T20:00:00.123+00:00"},"seven_day":{"utilization":42.5,"resets_at":"2026-11-10T09:00:00Z"},"extra":null}"#
        let limits = try #require(PlanLimitsClient.parseUsage(Data(json.utf8)))
        #expect(limits.session == LimitWindow(percentUsed: 12, resetsAt: ISODate.parse("2026-11-08T20:00:00.123Z")))
        #expect(limits.weekly == LimitWindow(percentUsed: 42.5, resetsAt: ISODate.parse("2026-11-10T09:00:00Z")))
    }

    @Test func idleSessionHasNoResetTime() throws {
        let json = #"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":5,"resets_at":"2026-11-10T09:00:00Z"}}"#
        let limits = try #require(PlanLimitsClient.parseUsage(Data(json.utf8)))
        #expect(limits.session == LimitWindow(percentUsed: 0, resetsAt: nil))
    }

    @Test func keepsWhicheverWindowIsPresent() throws {
        let limits = try #require(PlanLimitsClient.parseUsage(Data(#"{"five_hour":{"utilization":7}}"#.utf8)))
        #expect(limits.session?.percentUsed == 7)
        #expect(limits.weekly == nil)
    }

    @Test func rejectsUnexpectedResponse() {
        #expect(PlanLimitsClient.parseUsage(Data(#"{"seven_day":null,"five_hour":null}"#.utf8)) == nil)
        #expect(PlanLimitsClient.parseUsage(Data(#"{"seven_day":{"utilization":"high"}}"#.utf8)) == nil)
        #expect(PlanLimitsClient.parseUsage(Data(#"{"seven_day":{"utilization":true}}"#.utf8)) == nil) // not "1%"
        #expect(PlanLimitsClient.parseUsage(Data("oops".utf8)) == nil)
    }

    @Test func extraUsageSwitchedOff() throws {
        // Shape of the real response for an account that turned extra usage off.
        let json = #"""
        {"five_hour":{"utilization":21.0,"resets_at":"2026-11-08T09:50:00.093427+00:00"},
         "seven_day":{"utilization":66.0,"resets_at":"2026-11-11T16:00:00.093450+00:00"},
         "extra_usage":{"credits_ever_enabled":true,"currency":null,"decimal_places":null,"is_enabled":false,
                        "monthly_limit":null,"spend_limit_reached":false,"used_credits":null,"user_disabled":true,"utilization":null},
         "spend":{"enabled":false,"limit":null,"balance":null,"percent":0,"used":{"amount_minor":0,"currency":"USD","exponent":2}}}
        """#
        let extra = try #require(PlanLimitsClient.parseUsage(Data(json.utf8))?.extra)
        #expect(extra == ExtraUsage(isEnabled: false, used: Money(amount: 0, currency: "USD"), percentUsed: 0,
                                    limitReached: false, turnedOffByUser: true))
    }

    @Test func extraUsageWithAmounts() throws {
        let json = #"""
        {"five_hour":{"utilization":95},
         "spend":{"enabled":true,"percent":24.68,
                  "used":{"amount_minor":1234,"currency":"USD","exponent":2},
                  "limit":{"amount_minor":5000,"currency":"USD","exponent":2},
                  "balance":{"amount_minor":250,"currency":"usd","exponent":2}},
         "extra_usage":{"is_enabled":true,"spend_limit_reached":false,"used_credits":1234}}
        """#
        let extra = try #require(PlanLimitsClient.parseUsage(Data(json.utf8))?.extra)
        #expect(extra.isEnabled)
        #expect(extra.used == Money(amount: 12.34, currency: "USD"))
        #expect(extra.limit == Money(amount: 50, currency: "USD"))
        #expect(extra.balance == Money(amount: 2.5, currency: "USD"))
        #expect(extra.percentUsed == 24.68)
        #expect(!extra.limitReached)
    }

    @Test func extraUsageFlagsOnlyAndAbsent() throws {
        let flagsOnly = #"{"seven_day":{"utilization":5},"extra_usage":{"is_enabled":true,"utilization":30,"spend_limit_reached":true}}"#
        let extra = try #require(PlanLimitsClient.parseUsage(Data(flagsOnly.utf8))?.extra)
        #expect(extra.isEnabled && extra.limitReached && extra.percentUsed == 30)
        #expect(extra.used == nil) // its amount fields have no stated unit, so they're never read
        #expect(try #require(PlanLimitsClient.parseUsage(Data(#"{"seven_day":{"utilization":5}}"#.utf8))).extra == nil)
    }

    @Test func hostileExtraUsageValues() {
        #expect(PlanLimitsClient.money(["amount_minor": "lots", "exponent": 2] as [String: Any]) == nil)
        #expect(PlanLimitsClient.money(["amount_minor": 5, "exponent": 99] as [String: Any]) == nil)
        #expect(PlanLimitsClient.money(["amount_minor": true] as [String: Any]) == nil) // a JSON boolean isn't a number
        #expect(PlanLimitsClient.money(["amount_minor": 5, "currency": "<script>"] as [String: Any])?.currency == nil)
        #expect(PlanLimitsClient.money(["amount_minor": 1e300, "exponent": 0] as [String: Any])?.amount == 1e12)
        #expect(ExtraUsage(isEnabled: true, percentUsed: 1e9).percentUsed == 1_000)
        #expect(ExtraUsage(isEnabled: true, percentUsed: .nan).percentUsed == 0)
    }

    @Test func detectsPassedReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(-1)).hasReset(at: now))
        #expect(!LimitWindow(percentUsed: 50, resetsAt: now.addingTimeInterval(60)).hasReset(at: now))
        #expect(!LimitWindow(percentUsed: 0, resetsAt: nil).hasReset(at: now))
    }

    @Test func parsesCredentials() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1762600000000}}"#
        let c = try #require(PlanLimitsClient.parseCredentials(json))
        #expect(c.accessToken == "tok")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_762_600_000))
        #expect(PlanLimitsClient.parseCredentials("{}") == nil)
        #expect(PlanLimitsClient.parseCredentials(#"{"claudeAiOauth":{"accessToken":""}}"#) == nil)
    }

    @Test func refusesRedirects() async {
        // The request carries a bearer token: it must never be forwarded to another URL.
        let delegate = RefuseRedirects()
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.anthropic.com")!)
        let response = HTTPURLResponse(url: PlanLimitsClient.endpoint, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://evil.example"])!
        let next: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: "https://evil.example")!)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(next == nil)
    }
}

// MARK: - Network behaviour against a fake server

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&value) } }
}

private final class FakeServer: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private let okBody = #"{"five_hour":{"utilization":10,"resets_at":"2026-11-08T20:00:00Z"},"seven_day":{"utilization":37,"resets_at":"2026-11-12T16:00:00Z"}}"#

private func credentialsJSON(_ token: String, expiresInSeconds: Double = 3_600) -> String {
    let ms = (Date().timeIntervalSince1970 + expiresInSeconds) * 1000
    return #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(Int(ms))}}"#
}

private func makeClient(now: @escaping @Sendable () -> Date = { Date() },
                        readCredentials: @escaping @Sendable () -> String?) -> PlanLimitsClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FakeServer.self]
    return PlanLimitsClient(configuration: config, readCredentials: readCredentials, now: now)
}

@Suite(.serialized) struct PlanLimitsNetworkTests {
    @Test func sendsTokenAndParsesResponse() async throws {
        let seen = Box<[String: String]>([:])
        FakeServer.handler = { request in
            seen.set(request.allHTTPHeaderFields ?? [:])
            return (200, okBody)
        }
        let client = makeClient { credentialsJSON("tok-1") }
        let result = await client.fetch()
        #expect(try result.get().weekly?.percentUsed == 37)
        #expect(seen.get()["Authorization"] == "Bearer tok-1")
        #expect(seen.get()["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test func cachesCredentialsBetweenFetches() async {
        FakeServer.handler = { _ in (200, okBody) }
        let reads = Box(0)
        let client = makeClient {
            reads.update { $0 += 1 }
            return credentialsJSON("tok-1")
        }
        _ = await client.fetch()
        _ = await client.fetch()
        #expect(reads.get() == 1)
    }

    @Test func rereadsLoginPeriodicallyToNoticeAccountSwitch() async throws {
        let seen = Box("")
        FakeServer.handler = { request in
            seen.set(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (200, okBody)
        }
        let clock = Box(Date())
        let stored = Box("account-a")
        let client = makeClient(now: { clock.get() }) { credentialsJSON(stored.get(), expiresInSeconds: 86_400) }

        _ = await client.fetch()
        stored.set("account-b") // user switched accounts in Claude Code; old token still valid
        clock.update { $0.addTimeInterval(5 * 60) }
        _ = await client.fetch()
        #expect(seen.get() == "Bearer account-a") // within 10 min: cached

        clock.update { $0.addTimeInterval(6 * 60) }
        _ = await client.fetch()
        #expect(seen.get() == "Bearer account-b") // after 10 min: re-read
    }

    @Test func rereadsLoginAfter401AndRetriesOnce() async throws {
        // The server only accepts the refreshed token; Claude Code refreshed it in the Keychain.
        FakeServer.handler = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? (200, okBody) : (401, "{}")
        }
        let stored = Box("old")
        let client = makeClient { credentialsJSON(stored.get()) }
        _ = await client.fetch() // caches "old" (401)
        stored.set("new")
        let result = await client.fetch()
        #expect(try result.get().session?.percentUsed == 10)
    }

    @Test func reportsExpiredLoginWhenRetryDoesNotHelp() async {
        FakeServer.handler = { _ in (401, "{}") }
        let client = makeClient { credentialsJSON("same") }
        #expect(await client.fetch() == .failure(.loginExpired))
    }

    @Test func expiredLoginSkipsNetwork() async {
        let calls = Box(0)
        FakeServer.handler = { _ in
            calls.update { $0 += 1 }
            return (200, okBody)
        }
        let client = makeClient { credentialsJSON("tok", expiresInSeconds: -60) }
        #expect(await client.fetch() == .failure(.loginExpired))
        #expect(calls.get() == 0)
    }

    @Test func missingLogin() async {
        let client = makeClient { nil }
        #expect(await client.fetch() == .failure(.noCredentials))
    }

    @Test func mapsServerErrors() async {
        FakeServer.handler = { _ in (429, "{}") }
        #expect(await makeClient { credentialsJSON("t") }.fetch() == .failure(.rateLimited))
        FakeServer.handler = { _ in (503, "{}") }
        #expect(await makeClient { credentialsJSON("t") }.fetch() == .failure(.http(503)))
        FakeServer.handler = { _ in (200, "<html>") }
        #expect(await makeClient { credentialsJSON("t") }.fetch() == .failure(.badResponse))
    }

    @Test func oversizedResponseIsRefused() async throws {
        // Valid JSON padded with whitespace: it would parse fine if the size cap didn't stop it.
        let padded = okBody + String(repeating: " ", count: PlanLimitsClient.maxResponseBytes)
        FakeServer.handler = { _ in (200, padded) }
        #expect(await makeClient { credentialsJSON("t") }.fetch() == .failure(.badResponse))
        // Just under the cap is still accepted.
        let fits = okBody + String(repeating: " ", count: PlanLimitsClient.maxResponseBytes - okBody.utf8.count)
        FakeServer.handler = { _ in (200, fits) }
        let result = await makeClient { credentialsJSON("t") }.fetch()
        #expect(try result.get().weekly?.percentUsed == 37)
    }

    @Test func forbiddenMeansNotAvailableNotExpired() async {
        // 403: this account can't read limits; telling the user to re-login wouldn't help.
        FakeServer.handler = { _ in (403, "{}") }
        #expect(await makeClient { credentialsJSON("t") }.fetch() == .failure(.notAvailable))
    }

    @Test func signingOutShowsSignInNotExpired() async {
        FakeServer.handler = { _ in (401, "{}") }
        let stored = Box<String?>(credentialsJSON("t"))
        let client = makeClient { stored.get() }
        _ = await client.fetch()
        stored.set(nil) // user signed out of Claude Code
        #expect(await client.fetch() == .failure(.noCredentials))
    }
}

@Suite struct FormatTests {
    @Test func tokens() {
        #expect(Format.tokens(0) == "0")
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(12_300) == "12.3K")
        #expect(Format.tokens(4_560_000) == "4.56M")
        #expect(Format.tokens(1_000_000) == "1M")
        #expect(Format.tokens(1_200_000_000) == "1.2B")
    }

    @Test func tokensNeverShow1000OfAUnit() {
        #expect(Format.tokens(999_499) == "999K")
        #expect(Format.tokens(999_950) == "1M")
        #expect(Format.tokens(999_999_999) == "1B")
    }

    @Test func modelNames() {
        #expect(Format.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(Format.modelName("claude-fable-5-1") == "Fable 5.1")
        #expect(Format.modelName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(Format.modelName("claude-3-5-haiku-20241022") == "Haiku 3.5")
        #expect(Format.modelName("claude-3-opus-20240229") == "Opus 3")
        #expect(Format.modelName("claude-opus-4") == "Opus 4")
        #expect(Format.modelName("claude-sonnet-4-5[1m]") == "Sonnet 4.5 (1M)")
        // Unrecognized shapes are shown as logged, never mangled.
        for raw in ["unknown", "gpt-5", "claude-", "claude-3-7-sonnet-latest", "claude-opus-123", "claude-opus-4-5-thinking"] {
            #expect(Format.modelName(raw) == raw)
        }
    }

    @Test func money() {
        let us = Locale(identifier: "en_US")
        #expect(Format.money(Money(amount: 12.34, currency: "USD"), locale: us) == "$12.34")
        #expect(Format.money(Money(amount: 0, currency: "USD"), locale: us) == "$0.00")
        #expect(Format.money(Money(amount: 12.3, currency: nil), locale: us) == "12.30")
        #expect(Format.money(Money(amount: 12.34, currency: "EUR"), locale: Locale(identifier: "de_DE")).contains("12,34"))
    }

    @Test func headlineLeavesOutCacheReads() {
        let t = TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 1_000)
        #expect(t.excludingCacheReads == 6)
        #expect(t.total == 1_006)
        #expect(TokenCounts(input: .max, output: 1).excludingCacheReads == .max) // saturates, never traps
    }

    @Test func countdown() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(Format.countdown(to: now.addingTimeInterval(2 * 86_400 + 4 * 3_600), from: now) == "in 2d 4h")
        #expect(Format.countdown(to: now.addingTimeInterval(3 * 3_600 + 12 * 60), from: now) == "in 3h 12m")
        #expect(Format.countdown(to: now.addingTimeInterval(-5), from: now) == "now")
    }
}
