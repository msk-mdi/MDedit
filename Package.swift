// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MdEdit",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MdEdit", targets: ["MdEdit"]),
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
    ],
    targets: [
        .target(name: "MarkdownKit"),
        .executableTarget(name: "MdEdit", dependencies: ["MarkdownKit"]),
        // The spec fixtures are read from disk by path, not bundled.
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"], exclude: ["Fixtures"]),
        .testTarget(name: "MdEditTests", dependencies: ["MdEdit", "MarkdownKit"]),
    ]
)
