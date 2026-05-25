// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirDesk",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../Shared/AirDeskProtocol"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        .executableTarget(
            name: "AirDesk",
            dependencies: [
                "AirDeskProtocol",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AirDesk"
        )
    ]
)
