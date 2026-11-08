import AppKit
import UsageCore

/// Picks the menu bar icon, first match wins:
///
/// 1. The user's own `MenuBarIcon` file in `~/Library/Application Support/Tokenwick/`
///    (no rebuild needed, just relaunch).
/// 2. The icon bundled into the app from the repo's `assets/` folder by `scripts/bundle.sh`
///    (the Claude Code mascot).
/// 3. The ✦ SF Symbol, if neither exists (e.g. `swift run` without bundling).
///
/// Supported: `.pdf`, `.svg`, `.png`. Name it `MenuBarIcon.*` to draw it as a monochrome
/// template that matches the menu bar (light/dark), or `MenuBarIcon-color.*` to keep its colors.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    /// The user's custom icon, or nil if there isn't one. Loaded once.
    static let custom: NSImage? = {
        for (url, keepColor) in candidates() {
            // Read safely (regular file, max 2 MB): this runs on the main thread at launch,
            // where a FIFO or huge file at the icon path would freeze the app.
            if let data = SafeFile.read(url, maxBytes: 2 << 20),
               let image = NSImage(data: data), image.isValid {
                return prepared(image, template: !keepColor)
            }
        }
        return nil
    }()

    static func load() -> NSImage {
        if let custom { return custom }
        let fallback = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Tokenwick") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }

    private static func candidates() -> [(URL, Bool)] {
        var dirs: [URL] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(support.appendingPathComponent("Tokenwick"))
        }
        if let resources = Bundle.main.resourceURL { dirs.append(resources) }

        var result: [(URL, Bool)] = []
        for dir in dirs {
            for (name, keepColor) in [("MenuBarIcon-color", true), ("MenuBarIcon", false)] {
                for ext in ["pdf", "svg", "png"] {
                    let url = dir.appendingPathComponent("\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: url.path) { result.append((url, keepColor)) }
                }
            }
        }
        return result
    }

    /// Scales to fit 18×18 points, keeping the aspect ratio.
    private static func prepared(_ image: NSImage, template: Bool) -> NSImage {
        let original = image.size
        let scale = min(size.width / max(original.width, 1), size.height / max(original.height, 1))
        image.size = NSSize(width: original.width * scale, height: original.height * scale)
        image.isTemplate = template
        image.accessibilityDescription = "Tokenwick"
        return image
    }
}
