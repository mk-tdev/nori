// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Nori", platforms: [.macOS(.v14)], products: [.executable(name: "Nori", targets: ["Pulse"])], targets: [
    .target(name: "PulseSystem", linkerSettings: [.linkedFramework("IOKit")]),
    .executableTarget(name: "Pulse", dependencies: ["PulseSystem"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Metal")]),
    .testTarget(name: "NoriTests", dependencies: ["Pulse"], path: "Tests")
])
