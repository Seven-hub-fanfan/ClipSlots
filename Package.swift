// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipSlots",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClipSlots",
            path: "Sources/ClipSlots",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
    ]
)
