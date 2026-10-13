// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Radio",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "radio", targets: ["radio"]),
    ],
    targets: [
        .target(
            name: "RadioCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "radio",
            dependencies: ["RadioCore"]
        ),
        .testTarget(
            name: "RadioCoreTests",
            dependencies: ["RadioCore"]
        ),
    ]
)
