// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Curlbrew",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Curlbrew", targets: ["CurlbrewApp"])
    ],
    targets: [
        .target(name: "CellarCore", swiftSettings: swift5),
        .target(name: "CellarProviders", dependencies: ["CellarCore"], swiftSettings: swift5),
        .executableTarget(name: "CurlbrewApp", dependencies: ["CellarCore", "CellarProviders"], swiftSettings: swift5),
        .testTarget(name: "CellarCoreTests", dependencies: ["CellarCore"], swiftSettings: swift5),
        .testTarget(name: "CellarProvidersTests", dependencies: ["CellarCore", "CellarProviders"], swiftSettings: swift5),
    ]
)
