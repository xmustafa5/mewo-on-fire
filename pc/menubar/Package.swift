// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "mewo-menubar",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(name: "mewo-menubar", path: "Sources")
  ]
)
