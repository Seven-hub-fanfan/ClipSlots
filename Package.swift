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
        .testTarget(
            name: "ClipSlotsKitTests",
            dependencies: ["ClipSlotsKit"],
            path: "Tests/ClipSlotsKitTests"
        ),
        // 轻量测试运行器：本机仅装了 Command Line Tools（无完整 Xcode），
        // XCTest 不可用，`swift test` 跑不起来。这个 executable target 用零依赖的
        // 断言 harness 覆盖同样的关键路径，用 `swift run ClipSlotsKitSmokeTests` 运行，
        // 失败时以非零退出码结束，方便本地与 CI 快速自测。
        .executableTarget(
            name: "ClipSlotsKitSmokeTests",
            dependencies: ["ClipSlotsKit"],
            path: "Tests/ClipSlotsKitSmokeTests"
        ),
    ]
)
