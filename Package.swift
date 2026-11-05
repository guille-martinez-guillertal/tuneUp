// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "TuneUp",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "TuneUp", targets: ["TuneUp"])],
    targets: [
        .target(name: "TuneUpCore"),
        .executableTarget(name: "TuneUp", dependencies: ["TuneUpCore"]),
        .testTarget(name: "TuneUpCoreTests", dependencies: ["TuneUpCore"])
    ]
)
