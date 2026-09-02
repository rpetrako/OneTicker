// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OneTicker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OneTicker",
            path: "Sources/OneTicker"
        )
    ]
)
