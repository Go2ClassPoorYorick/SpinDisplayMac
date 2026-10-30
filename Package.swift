// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpinDisplayMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SpinDisplayMac", targets: ["SpinDisplayMac"]),
        .executable(name: "SpinDisplayStatusCLI", targets: ["SpinDisplayStatusCLI"]),
        .executable(name: "SpinDisplayMacProtocolTests", targets: ["SpinDisplayMacProtocolTests"])
    ],
    targets: [
        .target(name: "SpinDisplayCore"),
        .executableTarget(name: "SpinDisplayMac", dependencies: ["SpinDisplayCore"]),
        .executableTarget(name: "SpinDisplayStatusCLI", dependencies: ["SpinDisplayCore"]),
        .executableTarget(name: "SpinDisplayMacProtocolTests", dependencies: ["SpinDisplayCore"])
    ]
)
