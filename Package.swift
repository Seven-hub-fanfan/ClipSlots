// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipSlots",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ClipSlotsKit",
            path: "Sources/ClipSlotsKit"
        ),
        .executableTarget(
            name: "ClipSlots",
            dependencies: ["ClipSlotsKit"],
            path: "Sources/ClipSlots",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "ClipSlotsCLI",
            dependencies: ["ClipSlotsKit"],
            path: "Sources/ClipSlotsCLI"
        ),
    ]
)
