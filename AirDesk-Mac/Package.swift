// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirDesk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AirDesk",
            path: "Sources/AirDesk"
        )
    ]
)
