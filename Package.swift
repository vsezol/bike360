// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Bike360",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "Pipeline", targets: ["Pipeline"]),
    .executable(name: "bike360-cli", targets: ["bike360-cli"]),
  ],
  targets: [
    .target(
      name: "Pipeline",
      path: "Sources/Pipeline",
      resources: [
        .process("Modules/Undistorting/FisheyeUndistorter.metal"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
    .executableTarget(
      name: "bike360-cli",
      dependencies: ["Pipeline"],
      path: "Sources/bike360-cli",
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
    .testTarget(
      name: "PipelineTests",
      dependencies: ["Pipeline"],
      path: "Tests/PipelineTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
      ]
    ),
  ]
)
