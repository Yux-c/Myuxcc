// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Myuxcc",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Myuxcc",
            path: "Sources/Myuxcc"
        )
    ]
)
