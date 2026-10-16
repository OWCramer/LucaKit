// swift-tools-version: 6.0
// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import PackageDescription

let package = Package(
    name: "LucaKit",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18)],
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
