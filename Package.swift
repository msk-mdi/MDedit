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
        // The Quick Look preview extension. An app extension starts in
        // NSExtensionMain rather than main; Scripts/make-app.sh wraps the
        // binary in an .appex inside the app.
        .executableTarget(
            name: "MdEditQuickLook",
            dependencies: ["MarkdownKit"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .unsafeFlags(["-application-extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
                .linkedFramework("QuickLookUI"),
            ]
        ),
        // The spec fixtures are read from disk by path, not bundled.
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"], exclude: ["Fixtures"]),
        .testTarget(name: "MdEditTests", dependencies: ["MdEdit", "MarkdownKit"]),
    ]
)
