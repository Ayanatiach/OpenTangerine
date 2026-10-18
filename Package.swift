// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenTangerine",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "OpenTangerine", targets: ["OpenTangerine"])],
    targets: [.executableTarget(name: "OpenTangerine", path: "Sources/OpenTangerine")]
)
