import Foundation

// Loads distance-config.json into a DistanceEstimator. Lets us flip strategies
// on/off and retune their ranges without recompiling.
//
//   {
//     "cameraHeightMeters": 1.0,
//     "strategies": [
//       { "name": "groundPlane", "enabled": true, "minRangeMeters": 0,  "maxRangeMeters": 40 },
//       { "name": "pinhole", "enabled": true, "minRangeMeters": 40, "maxRangeMeters": 80, "maxHeightCapMeters": 2.0 }
//     ]
//   }
public struct DistanceConfig: Sendable {
  public let cameraHeightMeters: Float
  public let estimator: DistanceEstimator

  public init(cameraHeightMeters: Float, estimator: DistanceEstimator) {
    self.cameraHeightMeters = cameraHeightMeters
    self.estimator = estimator
  }

  public static func load(from url: URL) throws -> DistanceConfig {
    let data = try Data(contentsOf: url)
    let raw = try JSONDecoder().decode(RawConfig.self, from: data)
    let strategies: [DistanceStrategy] = raw.strategies.compactMap { Self.makeStrategy($0) }
    return DistanceConfig(
      cameraHeightMeters: raw.cameraHeightMeters,
      estimator: DistanceEstimator(
        strategies: strategies,
        cameraHeightMeters: raw.cameraHeightMeters
      )
    )
  }

  // Factory: map a config entry to a concrete strategy. New methods plug in
  // here — one case, no changes anywhere else.
  private static func makeStrategy(_ raw: RawStrategy) -> DistanceStrategy? {
    let lower = min(raw.minRangeMeters, raw.maxRangeMeters)
    let upper = max(raw.minRangeMeters, raw.maxRangeMeters)
    let range = lower...upper
    switch raw.name {
    case "groundPlane":
      return GroundPlaneStrategy(isEnabled: raw.enabled, rangeMeters: range)
    case "pinhole":
      return PinholeStrategy(
        isEnabled: raw.enabled,
        rangeMeters: range,
        maxHeightCapMeters: raw.maxHeightCapMeters ?? 2.0
      )
    default:
      return nil  // unknown strategy name — skip it
    }
  }

  private struct RawConfig: Decodable {
    let cameraHeightMeters: Float
    let strategies: [RawStrategy]
  }

  private struct RawStrategy: Decodable {
    let name: String
    let enabled: Bool
    let minRangeMeters: Float
    let maxRangeMeters: Float
    let maxHeightCapMeters: Float?
  }
}
