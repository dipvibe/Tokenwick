import Foundation

/// The app was called "Claude Usage Bar" during development. On first launch under the new
/// name, carry over its saved data (usage history, custom icon) and settings, so renaming
/// loses nothing. Does nothing once migrated, or if the old app never ran.
enum LegacyMigration {
    private static let oldFolder = "ClaudeUsageBar"
    private static let newFolder = "QuotaGoblin"
    private static let oldDefaultsDomain = "dev.claudeusagebar.ClaudeUsageBar"
    private static let settingKeys = ["showPercentInMenuBar", "planLimitsEnabled"]

    /// Call before anything reads settings or the cache.
    static func run() {
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let old = support.appendingPathComponent(oldFolder)
            let new = support.appendingPathComponent(newFolder)
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new) // a rename on the same disk: instant, keeps 0700
            }
        }
        // Only settings the user actually changed are stored, and only those not yet set here.
        if let legacy = UserDefaults(suiteName: oldDefaultsDomain) {
            let defaults = UserDefaults.standard
            for key in settingKeys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
    }
}
