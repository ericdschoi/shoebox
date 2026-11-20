// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShoeboxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShoeboxCore", targets: ["ShoeboxCore"])
    ],
    targets: [
        .target(name: "ShoeboxCore"),
        .testTarget(name: "ShoeboxCoreTests", dependencies: ["ShoeboxCore"])
    ]
)
