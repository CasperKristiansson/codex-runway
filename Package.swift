// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexRunway",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexRunway", targets: ["CodexRunway"])
    ],
    targets: [
        .executableTarget(name: "CodexRunway")
    ]
)
