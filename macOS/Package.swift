// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Recall", platforms: [.macOS("15.0")],
    products: [.executable(name: "Recall", targets: ["Rewind"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .executableTarget(name: "Rewind", dependencies: ["CSQLite"]),
        .testTarget(name: "RewindTests", dependencies: ["Rewind"])
    ]
)
