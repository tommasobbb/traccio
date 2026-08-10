// swift-tools-version:6.0
import PackageDescription

// TraccioCore holds the client's models, API client, and formatting. It builds
// and tests from the command line with no Xcode, which is what makes it
// verifiable by an agent (see docs/architecture.md, "Client"). The SwiftUI app
// target depends on this package and holds views/navigation only.
let package = Package(
    name: "TraccioCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TraccioCore", targets: ["TraccioCore"]),
    ],
    targets: [
        .target(name: "TraccioCore"),
        .testTarget(name: "TraccioCoreTests", dependencies: ["TraccioCore"]),
    ]
)
