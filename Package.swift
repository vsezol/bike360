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
        // .copy (not .process): the shader is compiled at runtime via
        // device.makeLibrary(source:), so it must ship as plain text. Under
        // Xcode 26 .process invokes the Metal compiler (a separate
        // downloadable toolchain) and fails the build; .copy just bundles
        // the raw file, which is all the runtime loader needs.
        .copy("Modules/Undistorting/FisheyeUndistorter.metal"),
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
