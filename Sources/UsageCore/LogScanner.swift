import Foundation

/// Reads Claude Code's session logs (`<config>/projects/**/*.jsonl`) and totals
/// token usage per day and model.
///
/// - Incremental: the byte offset reached in each file is cached, so a refresh only
///   parses lines appended since the last scan. Unchanged files cost no extra syscalls.
/// - Bounded memory: files are read in chunks, never whole.
/// - Deduplicated: one streamed response is logged on several lines (with identical
///   usage), so each `message.id` + `requestId` is counted once, across all files.
/// - History is kept: totals live in the app's own cache, so all-time numbers survive
///   Claude Code deleting old logs (after 30 days by default).
///
/// Not thread-safe: call `scan()` from one serial queue.
public final class LogScanner: @unchecked Sendable {
    struct FileState: Codable, Equatable {
        var offset: UInt64
        var inode: UInt64?
    }

    struct Cache: Codable {
        static let currentVersion = 2
        var version = Cache.currentVersion
        var files: [String: FileState] = [:]
        var days: DailyUsage = [:]
        /// 64-bit fingerprints of every response counted so far (see `fingerprint`).
        var seen: Set<Int64> = []
    }

    private let roots: [URL]
    private let cacheURL: URL?
    private let calendar: Calendar
    /// Read size. 1 MB keeps peak memory low; larger chunks don't make parsing faster.
    private let chunkSize: Int
    /// Lines longer than this are skipped instead of buffered, so one giant line (a huge
    /// tool output, or a crafted file) can't exhaust memory. Usage lines are a few KB.
    private let maxLineLength: Int
    /// Minimum seconds between cache writes. Unsaved progress is safe to lose: offsets,
    /// totals and dedupe data are always saved together, so lost work is simply redone.
    private let saveInterval: TimeInterval
    /// Loaded lazily by the first `scan()`, so app launch doesn't wait on disk.
    private var cache: Cache?
    private var dirty = false
    private var lastSave = Date.distantPast
    private let decoder = JSONDecoder()
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)
    /// No single response uses anywhere near this many tokens; anything above is corrupt.
    private static let maxTokensPerField = 1_000_000_000
    private static let maxCacheBytes = 256 << 20

    public convenience init(roots: [URL] = LogScanner.defaultRoots(),
                            cacheURL: URL? = LogScanner.defaultCacheURL(),
                            calendar: Calendar = .autoupdatingCurrent) {
        self.init(roots: roots, cacheURL: cacheURL, calendar: calendar,
                  chunkSize: 1 << 20, maxLineLength: 32 << 20, saveInterval: 60)
    }

    init(roots: [URL], cacheURL: URL?, calendar: Calendar, chunkSize: Int,
         maxLineLength: Int = 32 << 20, saveInterval: TimeInterval = 0) {
        self.roots = roots.map(\.standardizedFileURL)
        self.cacheURL = cacheURL
        self.calendar = calendar
        self.chunkSize = max(chunkSize, 1)
        self.maxLineLength = max(maxLineLength, 1)
        self.saveInterval = max(saveInterval, 0)
    }

    /// Where Claude Code keeps session logs: `$CLAUDE_CONFIG_DIR`, `~/.claude` and
    /// `~/.config/claude`. Symlinked duplicates are dropped so nothing is read twice.
    public static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = []
        if let env = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            dirs.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        dirs.append(home.appendingPathComponent(".claude"))
        dirs.append(home.appendingPathComponent(".config/claude"))

        var seen = Set<String>()
        return dirs
            .map { $0.appendingPathComponent("projects") }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
    }

    public static func defaultCacheURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tokenwick/usage-cache.plist")
    }

    /// Full scan: finds every log file and reads any new lines. Used at launch and as a
    /// safety net; day to day, `scan(changedPaths:)` does the work.
    @discardableResult
    public func scan() -> DailyUsage {
        withCache { cache, dayKey in
            var changed = false
            var present = Set<String>()
            for (url, size) in jsonlFiles() {
                present.insert(url.path)
                // A pool per file returns temporary Foundation objects right away, keeping peak memory low.
                if autoreleasepool(invoking: { scanFile(url, knownSize: size, cache: &cache, dayKey: dayKey) }) {
                    changed = true
                }
            }
            // Forget offsets of deleted logs. Their totals stay in `days`.
            let fileCount = cache.files.count
            cache.files = cache.files.filter { present.contains($0.key) }
            return changed || cache.files.count != fileCount
        }
    }

    /// Incremental scan of just these files, e.g. paths reported by `LogWatcher`. No directory
    /// walk. Paths that aren't `.jsonl` files inside a log folder are ignored.
    @discardableResult
    public func scan(changedPaths: [String]) -> DailyUsage {
        let realRoots = roots.map { ($0, Self.realPath($0)) }
        let urls = Set(changedPaths.compactMap { logURL(forEventPath: $0, realRoots: realRoots) })
        return withCache { cache, dayKey in
            var changed = false
            for url in urls where autoreleasepool(invoking: { scanFile(url, knownSize: nil, cache: &cache, dayKey: dayKey) }) {
                changed = true
            }
            return changed
        }
    }

    /// Writes unsaved progress to disk now (call before quitting).
    public func flush() {
        if dirty, let cache { save(cache) }
    }

    /// Folders to watch for new log lines: each log folder, or its parent if the log folder
    /// doesn't exist yet (so one created later, on first use of Claude Code, is noticed).
    public func directoriesToWatch() -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        return roots.compactMap { root -> URL? in
            if fm.fileExists(atPath: root.path) { return root }
            let parent = root.deletingLastPathComponent()
            return fm.fileExists(atPath: parent.path) ? parent : nil
        }
        .filter { seen.insert(Self.realPath($0)).inserted }
    }

    /// Number of files with saved progress (for tests).
    var trackedFileCount: Int { cache?.files.count ?? 0 }

    /// Runs `body` on the cache, then saves it if it changed and `saveInterval` has passed.
    private func withCache(_ body: (inout Cache, DayKey) -> Bool) -> DailyUsage {
        // Take the cache out of `self` so it's uniquely referenced and mutated in place
        // (otherwise the first mutation would copy the whole `seen` set).
        var cache = self.cache ?? loadCache()
        self.cache = nil
        // DayKey is built per scan so a time zone change is picked up without restarting.
        if body(&cache, DayKey(calendar: calendar)) { dirty = true }
        if dirty, Date().timeIntervalSince(lastSave) >= saveInterval { save(cache) }
        self.cache = cache
        return cache.days
    }

    /// Maps an FSEvents path (symlinks resolved, e.g. `/private/var/...`) back to the URL the
    /// directory walk would produce, so each file has exactly one cache entry.
    private func logURL(forEventPath path: String, realRoots: [(URL, String)]) -> URL? {
        guard path.hasSuffix(".jsonl") else { return nil }
        for (root, real) in realRoots {
            for base in [real, root.path] where path.hasPrefix(base + "/") {
                let relative = path.dropFirst(base.count + 1)
                // Same rule as the directory walk: skip anything inside a hidden folder.
                guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
                return root.appendingPathComponent(String(relative))
            }
        }
        return nil
    }

    /// The canonical path (all symlinks resolved), matching what FSEvents reports.
    /// Unlike `resolvingSymlinksInPath`, this keeps the `/private` prefix.
    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Files

    private func jsonlFiles() -> [(URL, UInt64)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var result: [(URL, UInt64)] = []
        for root in roots {
            // Walk the resolved folder: the enumerator doesn't follow a symlinked root (e.g. a
            // dotfiles-managed log folder) and would find nothing. Results are reported under
            // `root`, the same keys `scan(changedPaths:)` produces.
            let real = Self.realPath(root)
            // Prefetching the keys lets the enumerator fetch them in bulk (one syscall per directory batch).
            guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: real, isDirectory: true),
                                                                  includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let size = values.fileSize,
                      url.path.hasPrefix(real + "/") else { continue }
                result.append((root.appendingPathComponent(String(url.path.dropFirst(real.count + 1))), UInt64(size)))
            }
        }
        return result
    }

    /// Returns true if the cache changed.
    /// `knownSize` comes from the directory walk; nil means "check it" (FSEvents paths).
    private func scanFile(_ url: URL, knownSize: UInt64?, cache: inout Cache, dayKey: DayKey) -> Bool {
        let path = url.path
        var state = cache.files[path] ?? FileState(offset: 0, inode: nil)
        if let knownSize, knownSize == state.offset { return false } // unchanged: the common case

        // Open without following a symlink and without blocking (a FIFO swapped in after
        // enumeration would otherwise hang the scan forever), then confirm it's a regular
        // file on the open descriptor itself, so there's no check-then-open race.
        guard let (handle, info) = SafeFile.openRegular(url, followSymlinks: false) else { return false }
        let inode = UInt64(info.st_ino)
        let size = UInt64(max(info.st_size, 0))
        if size == state.offset, inode == state.inode { return false } // nothing new
        if state.inode != inode || size < state.offset {
            // New, replaced or truncated: read from the start. `seen` stops double counting.
            state = FileState(offset: 0, inode: inode)
        }
        guard (try? handle.seek(toOffset: state.offset)) != nil else { return false }

        var consumed: UInt64 = 0      // bytes fully handled, through the last newline
        var carry = Data()            // an incomplete line left over from the previous chunk
        var skipping = false          // inside a line longer than `maxLineLength`
        var skippedBytes: UInt64 = 0  // bytes of that line seen so far
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var data = chunk[...]
            if skipping {
                guard let newline = data.firstIndex(of: 0x0A) else {
                    skippedBytes += UInt64(data.count)
                    continue
                }
                consumed += skippedBytes + UInt64(data.distance(from: data.startIndex, to: newline) + 1)
                skipping = false
                skippedBytes = 0
                data = data[data.index(after: newline)...]
            }

            var buffer = carry
            buffer.append(contentsOf: data)
            carry = Data()
            if let lastNewline = buffer.lastIndex(of: 0x0A) {
                for line in buffer[buffer.startIndex..<lastNewline].split(separator: 0x0A, omittingEmptySubsequences: true)
                where line.count <= maxLineLength {
                    ingest(line, into: &cache, dayKey: dayKey)
                }
                consumed += UInt64(buffer.distance(from: buffer.startIndex, to: lastNewline) + 1)
                carry = Data(buffer[buffer.index(after: lastNewline)...])
            } else {
                carry = buffer
            }

            if carry.count > maxLineLength {
                skipping = true
                skippedBytes = UInt64(carry.count)
                carry = Data()
            }
        }
        // A trailing partial line (still being written) isn't consumed; it's re-read next scan.
        // So is an unfinished over-long line, which is then skipped again.

        guard consumed > 0 || state != cache.files[path] else { return false }
        state.offset += consumed
        cache.files[path] = state
        return true
    }

    // MARK: - Lines

    private struct LogLine: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?
            }
            let id: String?
            let model: String?
            let usage: Usage?
        }
        let type: String?
        let timestamp: String?
        let requestId: String?
        let uuid: String?
        let message: Message?
    }

    private func ingest(_ line: Data, into cache: inout Cache, dayKey: DayKey) {
        // Cheap byte filters before JSON decoding: most lines (user turns, tool results) have no usage.
        guard line.range(of: Self.usageMarker) != nil,
              line.range(of: Self.assistantMarker) != nil,
              let entry = try? decoder.decode(LogLine.self, from: Data(line)),
              entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let timestamp = entry.timestamp.flatMap(ISODate.parse) else { return }

        guard message.model != "<synthetic>" else { return } // generated locally by Claude Code, not an API call
        let model = Self.modelName(message.model)

        let tokens = TokenCounts(input: Self.sane(usage.input_tokens),
                                 output: Self.sane(usage.output_tokens),
                                 cacheWrite: Self.sane(usage.cache_creation_input_tokens),
                                 cacheRead: Self.sane(usage.cache_read_input_tokens))
        guard tokens.total > 0 else { return }

        let ids = [message.id, entry.requestId].compactMap { $0 }
        let key = ids.isEmpty ? entry.uuid : ids.joined(separator: ":")
        if let key, !key.isEmpty {
            guard cache.seen.insert(Self.fingerprint(key)).inserted else { return }
        }

        cache.days[dayKey.key(for: timestamp), default: [:]][model, default: .zero].add(tokens)
    }

    /// Clamps a logged token count to 0...maxTokensPerField. Negative or absurd values come
    /// only from corrupted or crafted logs.
    private static func sane(_ value: Int?) -> Int {
        min(max(value ?? 0, 0), maxTokensPerField)
    }

    /// Real model names are short ("claude-opus-5-5"). Cap them so a corrupted or crafted
    /// line can't put a multi-megabyte key into the cache for every day it appears.
    /// Counted in Unicode scalars, not Characters: one Character can hold any number of
    /// combining marks.
    static func modelName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unknown" }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.prefix(maxModelNameLength))
        return String(scalars)
    }
    static let maxModelNameLength = 100

    /// FNV-1a, 64-bit. Stable across launches (unlike `Hasher`) and much smaller to store
    /// than the full ID. Collisions are negligible: about 1 in 30 million at a million responses.
    static func fingerprint(_ key: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return Int64(bitPattern: hash)
    }

    // MARK: - Cache

    private func loadCache() -> Cache {
        guard let url = cacheURL else { return Cache() }
        if let data = SafeFile.read(url, maxBytes: Self.maxCacheBytes, followSymlinks: false),
           let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
           cache.version == Cache.currentVersion {
            return cache
        }
        // Clean up the JSON cache written by v0.1 development builds.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("usage-cache.json"))
        return Cache()
    }

    private func save(_ cache: Cache) {
        lastSave = Date() // also on failure, so a broken disk isn't retried on every scan
        guard let url = cacheURL else { dirty = false; return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary // compact, fast, and exact for 64-bit integers
        guard let data = try? encoder.encode(cache) else { return }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Also tighten a folder created by an older build with default (world-readable) permissions.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) // private to this user
        dirty = false
    }
}
