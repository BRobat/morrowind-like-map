// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MorrowindMap",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "MorrowindMapCore", targets: ["MorrowindMapCore"]),
        .library(name: "MorrowindMapUI", targets: ["MorrowindMapUI"]),
    ],
    targets: [
        // Platform-independent logic: tile math, decoding, rendering into RGBA
        // buffers, fog of war. Apple-only parts (ImageIO, HealthKit,
        // WatchConnectivity) are behind `#if canImport`.
        .target(
            name: "MorrowindMapCore",
            resources: [.copy("Resources/palette.json")]
        ),
        // SwiftUI map view shared by the iOS and watchOS apps.
        .target(
            name: "MorrowindMapUI",
            dependencies: ["MorrowindMapCore"]
        ),
        .testTarget(
            name: "MorrowindMapCoreTests",
            dependencies: ["MorrowindMapCore"]
        ),
    ]
)
