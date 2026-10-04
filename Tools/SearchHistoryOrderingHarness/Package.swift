// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SearchHistoryOrderingHarness",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "TiebaPlusPlus"),
    .testTarget(name: "TiebaPlusPlusTests", dependencies: ["TiebaPlusPlus"]),
  ]
)
