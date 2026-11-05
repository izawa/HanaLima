// swift-tools-version: 6.0
// lima-driver-hanalima: HanaLima's VM driver for Lima's external-driver interface (docs/09).
// A separate package so the app's build doesn't carry the gRPC stack. The protobuf sources
// under Sources/lima-driver-hanalima/Generated are committed; regenerate them from
// ../driver.proto with protoc + protoc-gen-swift + protoc-gen-grpc-swift-2 when it changes.
import PackageDescription

let package = Package(
    name: "LimaDriver",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "lima-driver-hanalima", targets: ["lima-driver-hanalima"])],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.2"),
    ],
    targets: [
        .executableTarget(
            name: "lima-driver-hanalima",
            dependencies: [
                .product(name: "LimaKit", package: "HanaLima"),
                .product(name: "NetworkKit", package: "HanaLima"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            linkerSettings: [.linkedFramework("Virtualization")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
