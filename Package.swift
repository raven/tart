// swift-tools-version:5.5

import PackageDescription

let package = Package(
  name: "Tart",
  platforms: [
    .macOS(.v12)
  ],
  products: [
    .executable(name: "tart", targets: ["tart"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.1.2"),
    .package(url: "https://github.com/pointfreeco/swift-parsing", from: "0.9.2"),
  ],
  targets: [
    .executableTarget(name: "tart",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Parsing", package: "swift-parsing"),
      ],
      plugins: [.plugin(name: "SwiftEntitlementsPlugin")]),
    .testTarget(name: "TartTests", dependencies: ["tart"]),
    .plugin(
      name: "SwiftEntitlementsPlugin",
      capability: .buildTool(),
      dependencies: ["codesign"]
    ),
    .binaryTarget(name: "codesign", path: "artifacts/codesign.artifactbundle")
  ]
)
