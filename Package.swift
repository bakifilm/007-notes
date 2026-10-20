// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notes007",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Notes007", path: "Sources/Notes007")
    ]
)
