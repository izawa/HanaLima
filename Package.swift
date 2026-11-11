// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HanaLima",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LimaKit", targets: ["LimaKit"]),
        .library(name: "NetworkKit", targets: ["NetworkKit"]),
        .executable(name: "HanaLima", targets: ["HanaLima"]),
        .executable(name: "hanalima-netd", targets: ["hanalima-netd"]),
        .executable(name: "hanalima-mcp", targets: ["hanalima-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0")),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(name: "LimaKit", dependencies: ["Yams"]),
        .target(name: "NetworkKit"),
        // MCP (docs/14): the protocol, the tool catalog and the app's Unix socket. Foundation only.
        .target(name: "MCPKit"),
        .executableTarget(name: "hanalima-mcp", dependencies: ["MCPKit"]),
        .executableTarget(name: "hanalima-netd", dependencies: ["NetworkKit"]),
        .executableTarget(
            name: "HanaLima",
            dependencies: [
                "LimaKit",
                "NetworkKit",
                "MCPKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(name: "MCPKitTests", dependencies: ["MCPKit"]),
        .testTarget(name: "NetworkKitTests", dependencies: ["NetworkKit", "LimaKit"]),
        .testTarget(
            name: "LimaKitTests",
            dependencies: ["LimaKit", "NetworkKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
