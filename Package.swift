// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shekef",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Shekef", path: "Sources/Shekef",
                          swiftSettings: [.unsafeFlags(["-swift-version", "5"])])
    ]
)
