// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshCoreKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeshCoreKit", targets: ["MeshCoreKit"]),
    ],
    targets: [
        .target(name: "MeshCoreKit"),
        .testTarget(name: "MeshCoreKitTests", dependencies: ["MeshCoreKit"]),
    ]
)
