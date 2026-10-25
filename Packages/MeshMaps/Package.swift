// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshMaps",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeshMaps", targets: ["MeshMaps"]),
    ],
    targets: [
        .target(name: "MeshMaps"),
        .testTarget(name: "MeshMapsTests", dependencies: ["MeshMaps"]),
    ]
)
