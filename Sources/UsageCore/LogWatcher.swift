import CoreServices
import Foundation

/// Watches directories with FSEvents and reports which files changed.
///
/// This replaces polling: the app does no work at all until Claude Code actually writes
/// a log. FSEvents also batches bursts of writes (`latency`) into a single callback.
public final class LogWatcher: @unchecked Sendable {
    /// Paths that changed, and whether FSEvents lost track (so a full rescan is needed).
    public typealias Handler = (_ changedPaths: [String], _ needsFullScan: Bool) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler

    /// Starts watching immediately. Returns nil if there's nothing to watch or FSEvents fails.
    /// - Parameters:
    ///   - latency: seconds to wait and batch events before calling `handler`.
    ///   - queue: where `handler` runs.
    public init?(directories: [URL], latency: TimeInterval, queue: DispatchQueue, handler: @escaping Handler) {
        // FSEvents matches canonical paths only: a symlinked folder (e.g. a dotfiles-managed
        // ~/.claude) or /var → /private/var would otherwise never report anything.
        let paths = directories.map { url -> String in
            guard let real = realpath(url.path, nil) else { return url.path }
            defer { free(real) }
            return String(cString: real)
        }
        guard !paths.isEmpty else { return nil }
        self.handler = handler

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream) // no callbacks after this, so the unretained `info` is safe
        FSEventStreamRelease(stream)
    }

    private static let fullScanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                               | kFSEventStreamEventFlagUserDropped
                                                               | kFSEventStreamEventFlagKernelDropped
                                                               | kFSEventStreamEventFlagRootChanged)

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
        // With kFSEventStreamCreateFlagUseCFTypes, `paths` is a CFArray of CFStrings.
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var changed: [String] = []
        changed.reserveCapacity(count)
        var needsFullScan = false
        for index in 0..<count {
            if flags[index] & fullScanFlags != 0 { needsFullScan = true }
            if let path = list[index] as? String { changed.append(path) }
        }
        watcher.handler(changed, needsFullScan)
    }
}
