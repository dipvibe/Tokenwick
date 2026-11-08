// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuotaGoblin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaGoblin", targets: ["QuotaGoblin"]),
    ],
    targets: [
        // Pure logic: log scanning and watching, aggregation, the plan-limits client. No UI.
        .target(name: "UsageCore"),
        // The menu bar app: an AppKit status item and a popover panel drawn with SwiftUI.
        .executableTarget(name: "QuotaGoblin", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
