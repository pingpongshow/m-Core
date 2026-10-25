// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshStore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeshStore", targets: ["MeshStore"]),
    ],
    targets: [
        .target(name: "MeshStore"),
        .testTarget(name: "MeshStoreTests", dependencies: ["MeshStore"]),
    ]
)
