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
    ],
    targets: [
        .target(name: "MeshServices", dependencies: ["MeshCoreKit", "MeshStore"]),
        .testTarget(name: "MeshServicesTests", dependencies: ["MeshServices"]),
    ]
)
