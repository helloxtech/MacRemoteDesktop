// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirDeskProtocol",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AirDeskProtocol", targets: ["AirDeskProtocol"]),
    ],
    targets: [
        .target(name: "AirDeskProtocol"),
    ]
)
