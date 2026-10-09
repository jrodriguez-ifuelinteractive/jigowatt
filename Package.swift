// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jigowatt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Jigowatt", targets: ["Jigowatt"]),
        .executable(name: "jigowatt-mcp", targets: ["jigowatt-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.0"),
    ],
    targets: [
        .target(name: "JigowattCore"),
        // Built from vendor/ghostty with `make ghostty` (needs Zig 0.16 + Xcode Metal toolchain).
        .binaryTarget(name: "GhosttyKit", path: "vendor/ghostty/macos/GhosttyKit.xcframework"),
        .executableTarget(
            name: "Jigowatt",
            dependencies: ["JigowattCore", "GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "jigowatt-mcp",
            dependencies: ["JigowattCore", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(name: "JigowattCoreTests", dependencies: ["JigowattCore"]),
    ],
    swiftLanguageModes: [.v5]
)
