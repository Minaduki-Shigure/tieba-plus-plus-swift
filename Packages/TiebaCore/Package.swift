// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "TiebaCore",
  platforms: [
    .iOS(.v16),
    .macOS(.v13),
  ],
  products: [
    .library(name: "TiebaCore", targets: ["TiebaCore"]),
    .library(name: "TiebaProto", targets: ["TiebaProto"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-protobuf.git",
      exact: "1.38.1"
    )
  ],
  targets: [
    .target(
      name: "TiebaProto",
      dependencies: [
        .product(name: "SwiftProtobuf", package: "swift-protobuf")
      ],
      exclude: ["LICENSE.aiotieba", "NOTICE.md"],
      plugins: [
        .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")
      ]
    ),
    .target(
      name: "TiebaCore",
      dependencies: [
        "TiebaProto",
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]
    ),
    .testTarget(
      name: "TiebaCoreTests",
      dependencies: ["TiebaCore", "TiebaProto"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
