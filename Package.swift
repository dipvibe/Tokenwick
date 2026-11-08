// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tokenwick",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tokenwick", targets: ["Tokenwick"]),
    ],
    targets: [
        // Pure logic: log scanning and watching, aggregation, the plan-limits client. No UI.
        .target(name: "UsageCore"),
        // The menu bar app: an AppKit status item and a popover panel drawn with SwiftUI.
        .executableTarget(name: "Tokenwick", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
