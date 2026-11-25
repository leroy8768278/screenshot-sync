// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenshotSyncMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ScreenshotSyncMac", targets: ["ScreenshotSyncMac"])],
    targets: [
        .executableTarget(name: "ScreenshotSyncMac"),
        .testTarget(name: "ScreenshotSyncMacTests", dependencies: ["ScreenshotSyncMac"])
    ]
)
