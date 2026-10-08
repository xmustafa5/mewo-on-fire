// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "mewo-console",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(name: "mewo-console", path: "Sources")
  ]
)
