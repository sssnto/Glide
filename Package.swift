// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GlideCore", platforms: [.macOS(.v13)], products: [.library(name: "GlideCore", targets: ["GlideCore"])], targets: [.target(name: "GlideCore", path: "Glide/Core"), .testTarget(name: "GlideCoreTests", dependencies: ["GlideCore"], path: "Tests")])
