// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MeetingTruthMacApp",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MeetingTruth", targets: ["MeetingTruth"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingTruth"
        )
    ]
)
