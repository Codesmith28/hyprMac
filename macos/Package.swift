// swift-tools-version:6.0
// Built by `make` (see mk/swift.mk) — libhyprcore.a must exist in build/release first.
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "hyprMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hyprMac", targets: ["HyprApp"]),
        .executable(name: "hyprmac-fixture", targets: ["FixtureApp"]),
        .executable(name: "hyprmac-e2e", targets: ["HyprE2E"]),
    ],
    targets: [
        // C API of the C++ core (core/include/hypr/hypr_core.h), linked from build/release/libhyprcore.a
        .systemLibrary(name: "CHyprCore", path: "Sources/CHyprCore"),

        // macOS adapters (AX, spaces, displays, hotkeys, executor, drag-trick mover) behind protocols.
        .target(name: "HyprPlatform", path: "Sources/HyprPlatform", swiftSettings: v5,
                linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit"),
                                 .linkedFramework("Carbon")]),
        .testTarget(name: "HyprPlatformTests", dependencies: ["HyprPlatform"],
                    path: "Tests/HyprPlatformTests", swiftSettings: v5),

        // Event coordinator: platform events -> engine -> geometry executor.
        .target(name: "HyprKit", dependencies: ["CHyprCore", "HyprPlatform"],
                path: "Sources/HyprKit", swiftSettings: v5),
        .testTarget(name: "HyprKitTests", dependencies: ["HyprKit", "HyprPlatform"],
                    path: "Tests/HyprKitTests", swiftSettings: v5),

        // Menu bar app shell.
        .executableTarget(name: "HyprApp", dependencies: ["HyprKit", "HyprPlatform"],
                          path: "Sources/HyprApp", swiftSettings: v5),

        // Test fixture app + end-to-end harness (real macOS, needs Accessibility).
        .executableTarget(name: "FixtureApp", path: "Sources/FixtureApp", swiftSettings: v5),
        .executableTarget(name: "HyprE2E", path: "Sources/HyprE2E", swiftSettings: v5),
    ]
)
