// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PixelFinder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "PixelFinder", path: "Sources/PixelFinder")
    ]
)
