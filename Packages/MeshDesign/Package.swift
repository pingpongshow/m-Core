// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeshDesign",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MeshDesign", targets: ["MeshDesign"]),
    ],
    targets: [
        .target(name: "MeshDesign"),
        .testTarget(name: "MeshDesignTests", dependencies: ["MeshDesign"]),
    ]
)
