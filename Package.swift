// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpinDisplayMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SpinDisplayMac", targets: ["SpinDisplayMac"]),
        .executable(name: "SpinDisplayStatusCLI", targets: ["SpinDisplayStatusCLI"]),
        .executable(name: "SpinDisplayMacProtocolTests", targets: ["SpinDisplayMacProtocolTests"]),
        .executable(name: "SpinDisplayConvertCLI", targets: ["SpinDisplayConvertCLI"])
    ],
    targets: [
        .target(name: "SpinDisplayCore"),
        .target(name: "SpinDisplayMedia", dependencies: ["SpinDisplayCore"]),
        .executableTarget(name: "SpinDisplayMac", dependencies: ["SpinDisplayCore", "SpinDisplayMedia"]),
        .executableTarget(name: "SpinDisplayConvertCLI", dependencies: ["SpinDisplayCore", "SpinDisplayMedia"]),
        .executableTarget(name: "SpinDisplayStatusCLI", dependencies: ["SpinDisplayCore"]),
        .executableTarget(name: "SpinDisplayMacProtocolTests", dependencies: ["SpinDisplayCore", "SpinDisplayMedia"])
    ]
)
