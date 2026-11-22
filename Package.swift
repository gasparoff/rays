// swift-tools-version:5.10
import PackageDescription

// Light System — console luci nativa macOS (SwiftUI) per ENTTEC ODE MK3 via Art-Net
// con sincronizzazione Ableton Link (SDK ufficiale, GPLv2+, vedi README).
let package = Package(
    name: "LightSystem",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LightSystem", targets: ["LightSystem"]),
        .library(name: "LightCore", targets: ["LightCore"]),
    ],
    targets: [
        // Ponte C sottile sopra l'SDK C++ ufficiale di Ableton Link (header-only + ASIO standalone).
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
        // Nucleo Foundation-only: Art-Net, scoperta, patch, scene, motore 30 Hz. Testabile senza UI.
        .target(
            name: "LightCore",
            path: "Sources/LightCore"
        ),
        .executableTarget(
            name: "LightSystem",
            dependencies: ["LightCore", "LinkBridge"],
            path: "Sources/LightSystem"
        ),
        .testTarget(
            name: "LightCoreTests",
            dependencies: ["LightCore", "LinkBridge"],
            path: "Tests/LightCoreTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
