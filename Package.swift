// swift-tools-version:5.10
import PackageDescription

// RAYS — native macOS (SwiftUI) lighting console for ENTTEC ODE MK3 over Art-Net,
// synchronised with Ableton Link (official SDK, GPLv2+, see README).
//
// Module layers (lower layers never import higher ones):
//   RaysOutput, RaysTempo   Foundation-only leaves: Art-Net/UDP output, tempo maths
//   RaysCore                fixtures, patch, scenes, choreography, sequencer (uses RaysOutput addresses)
//   RaysControl             MIDI decoding, controller layouts, routing to actions
//   RaysEngine              30 Hz engine, persisted configuration
//   RaysApp                 SwiftUI app (executable "LightSystem")

// Complete data-race checking for the library modules. CI fails on any compiler warning from
// these targets (see .github/workflows/ci.yml), so a concurrency diagnostic cannot slip in.
let strictConcurrency: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]

let package = Package(
    name: "LightSystem",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LightSystem", targets: ["RaysApp"]),
        .library(name: "RaysEngine", targets: ["RaysEngine"]),
    ],
    targets: [
        // Thin C bridge over the official Ableton Link C++ SDK (header-only + standalone ASIO).
        .target(
            name: "LinkBridge",
            path: "Sources/LinkBridge",
            cxxSettings: [
                .headerSearchPath("../../Vendor/link/include"),
                .headerSearchPath("../../Vendor/link/modules/asio-standalone/asio/include"),
                .define("LINK_PLATFORM_MACOSX", to: "1"),
                .define("ASIO_STANDALONE", to: "1"),
                .define("ASIO_NO_DEPRECATED", to: "1"),
            ]
        ),
        .target(name: "RaysOutput", path: "Sources/RaysOutput", swiftSettings: strictConcurrency),
        .target(name: "RaysTempo", path: "Sources/RaysTempo", swiftSettings: strictConcurrency),
        .target(name: "RaysCore", dependencies: ["RaysOutput"], path: "Sources/RaysCore", swiftSettings: strictConcurrency),
        .target(name: "RaysControl", dependencies: ["RaysCore"], path: "Sources/RaysControl", swiftSettings: strictConcurrency),
        .target(
            name: "RaysEngine",
            dependencies: ["RaysCore", "RaysOutput", "RaysTempo", "RaysControl"],
            path: "Sources/RaysEngine",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "RaysApp",
            dependencies: ["RaysEngine", "RaysCore", "RaysOutput", "RaysTempo", "RaysControl", "LinkBridge"],
            path: "Sources/RaysApp"
        ),
        .testTarget(
            name: "RaysTests",
            dependencies: ["RaysEngine", "RaysCore", "RaysOutput", "RaysTempo", "RaysControl", "LinkBridge"],
            path: "Tests/RaysTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
