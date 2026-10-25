// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshServices",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeshServices", targets: ["MeshServices"]),
    ],
    dependencies: [
        .package(path: "../MeshCoreKit"),
        .package(path: "../MeshStore"),
        .package(path: "../MeshTools"),
    ],
    targets: [
        .target(name: "MeshServices", dependencies: ["MeshCoreKit", "MeshStore", "MeshTools"]),
        .testTarget(name: "MeshServicesTests", dependencies: ["MeshServices"]),
    ]
)
