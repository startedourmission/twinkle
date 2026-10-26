// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Widgent",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Widgent")
    ]
)
