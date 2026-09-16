// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dyno",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .testTarget(name: "DynoKitTests", dependencies: ["DynoKit"]),
        .target(
            name: "DynoKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Dyno",
            dependencies: ["DynoKit", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "probe",
            dependencies: ["DynoKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
