// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshTools",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeshTools", targets: ["MeshTools"]),
    ],
    dependencies: [
        .package(path: "../MeshCoreKit"),
    ],
    targets: [
        .target(name: "MeshTools", dependencies: [.product(name: "MeshCoreKit", package: "MeshCoreKit")]),
        .testTarget(name: "MeshToolsTests", dependencies: ["MeshTools"]),
    ]
)
