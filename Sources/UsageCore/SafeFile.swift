import Foundation

/// Reads small files defensively.
///
/// `Data(contentsOf:)` and `String(contentsOf:)` block forever on a FIFO and will happily
/// read `/dev/zero` until memory runs out. Anything swapped in at a path the app reads
/// could otherwise freeze or crash it. This opens without blocking, confirms it's a regular
/// file via the open descriptor (no check-then-open race), and caps the size.
public enum SafeFile {
    /// Opens `url` read-only. Returns the handle only if it's a regular file.
    /// `followSymlinks: false` refuses a symlink as the final path component.
    static func openRegular(_ url: URL, followSymlinks: Bool = true) -> (FileHandle, stat)? {
        var flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
        if !followSymlinks { flags |= O_NOFOLLOW }
        let fd = open(url.path, flags)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (handle, info)
    }

    /// The whole file, or nil if it's missing, not a regular file, or larger than `maxBytes`.
    public static func read(_ url: URL, maxBytes: Int, followSymlinks: Bool = true) -> Data? {
        guard let (handle, info) = openRegular(url, followSymlinks: followSymlinks),
              info.st_size >= 0, info.st_size <= off_t(maxBytes) else { return nil }
        // Read one byte past the limit to catch a file that grew after fstat.
        // (`read(upToCount:)` returns nil at end of file, i.e. for an empty file.)
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { return nil }
        return data.count <= maxBytes ? data : nil
    }
}
