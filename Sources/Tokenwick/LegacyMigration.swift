import Foundation

/// The app was called "Claude Usage Bar" during development and "Quota Goblin" in v0.1.0.
/// On first launch as Tokenwick, carry over the saved data (usage history, custom icon) and
/// settings from whichever older version ran, so renaming loses nothing. Newest name first.
/// Does nothing once migrated, or if no older version ever ran.
enum LegacyMigration {
    private static let newFolder = "Tokenwick"
    /// (Application Support folder, UserDefaults domain) of each older name, newest first.
    private static let older = [
        ("QuotaGoblin", "dev.quotagoblin.QuotaGoblin"),
        ("ClaudeUsageBar", "dev.claudeusagebar.ClaudeUsageBar"),
    ]
    private static let settingKeys = ["showPercentInMenuBar", "planLimitsEnabled"]

    /// Call before anything reads settings or the cache.
    static func run() {
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let new = support.appendingPathComponent(newFolder)
            for (folder, _) in older where !fm.fileExists(atPath: new.path) {
                let old = support.appendingPathComponent(folder)
                if fm.fileExists(atPath: old.path) {
                    try? fm.moveItem(at: old, to: new) // a rename on the same disk: instant, keeps 0700
                }
            }
        }
        // Only settings the user actually changed are stored, and only those not yet set here.
        let defaults = UserDefaults.standard
        for (_, domain) in older {
            guard let legacy = UserDefaults(suiteName: domain) else { continue }
            for key in settingKeys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }
    }
}
