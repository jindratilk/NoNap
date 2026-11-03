// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoNap",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "NoNap", targets: ["NoNap"])
    ],
    targets: [
        .executableTarget(name: "NoNap", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NoNapTests", dependencies: ["NoNap"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
