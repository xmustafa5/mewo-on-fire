// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ccnotify-menubar",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(name: "ccnotify-menubar", path: "Sources")
  ]
)
