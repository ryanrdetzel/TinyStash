// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tiny Stash",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyStash", targets: ["TinyStash"])
    ],
    targets: [
        .executableTarget(
            name: "TinyStash",
            path: "Sources/TinyStash"
        ),
        .testTarget(
            name: "TinyStashTests",
            dependencies: ["TinyStash"],
            path: "Tests/TinyStashTests"
        )
    ]
)
