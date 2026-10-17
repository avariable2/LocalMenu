// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalMenu",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LocalLLM"),
        .executableTarget(name: "LocalMenu", dependencies: ["LocalLLM"]),
        .testTarget(name: "LocalLLMTests", dependencies: ["LocalLLM"]),
        .testTarget(name: "LocalMenuTests", dependencies: ["LocalMenu", "LocalLLM"])
    ]
)
