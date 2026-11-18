// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Spotified", platforms: [.macOS(.v13)], products: [.executable(name: "Spotified", targets: ["Spotified"])], targets: [.executableTarget(name: "Spotified")])
