// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoNap",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "NoNap", targets: ["NoNap"])
    ],
    targets: [
        .executableTarget(name: "NoNap")
    ]
)
