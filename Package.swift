// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LucaKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
    products: [
        .library(name: "LucaKit", targets: ["LucaKit"]),
        .executable(name: "luca-cli", targets: ["luca-cli"]),
    ],
    targets: [
        // Optimised even in Debug: the image decoders run per picture, and unoptimised
        // Swift takes seconds over a 3840×2160 background.
        .target(name: "LucaKit", swiftSettings: [.unsafeFlags(["-O"])]),
        // Developer tool: lists archives, dumps scripts and exports images from the Mac.
        .executableTarget(name: "luca-cli", dependencies: ["LucaKit"]),
        .testTarget(name: "LucaKitTests", dependencies: ["LucaKit"]),
    ]
)
