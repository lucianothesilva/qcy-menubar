// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QCYMenubar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QCYMenubar", targets: ["QCYMenubar"])
    ],
    targets: [
        .executableTarget(
            name: "QCYMenubar",
            path: "Sources/QCYMenubar"
        )
    ]
)
