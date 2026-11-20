// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DevPulse",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        // The macOS app (bundle assembled by build.sh — see development_workflow.md §2).
        .executable(name: "DevPulse", targets: ["DevPulse"]),
        // App logic without UI — what `swift test` covers.
        .library(name: "DevPulseCore", targets: ["DevPulseCore"]),
    ],
    dependencies: [
        // Auto-update: the standard updater for apps outside the App Store;
        // EdDSA-signed appcast on GitHub Pages.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
    ],
    targets: [
        .target(
            name: "DevPulseCore",
            path: "Sources/DevPulseCore"
        ),
        .executableTarget(
            name: "DevPulse",
            dependencies: [
                "DevPulseCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DevPulse",
            linkerSettings: [
                // Embedded frameworks ship in Contents/Frameworks (build.sh).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "DevPulseCoreTests",
            dependencies: ["DevPulseCore"],
            path: "Tests/DevPulseCoreTests",
            // Read by path (#filePath), not bundled.
            exclude: ["Fixtures"]
        ),
    ]
)
