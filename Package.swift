// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LucaKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LucaKit", targets: ["LucaKit"]),
        .executable(name: "luca-cli", targets: ["luca-cli"]),
    ],
    targets: [
        .target(name: "LucaKit"),
        // Developer tool: lists archives, dumps scripts and exports images from the Mac.
        .executableTarget(name: "luca-cli", dependencies: ["LucaKit"]),
        .testTarget(name: "LucaKitTests", dependencies: ["LucaKit"]),
    ]
)
