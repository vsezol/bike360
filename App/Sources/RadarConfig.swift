import Foundation

// Tunable parameters for the 3D radar, loaded from radar-config.json in the
// bundle so they can be adjusted without recompiling. Falls back to sane
// defaults if the file is missing or malformed.
struct RadarConfig: Decodable {
  // Objects farther than this from the rider are not drawn. The distance
  // rings, ground grid and camera all scale to this radius.
  let maxDisplayRadiusMeters: Float

  static let fallback = RadarConfig(maxDisplayRadiusMeters: 50)

  static func loadFromBundle(named name: String = "radar-config") -> RadarConfig {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let config = try? JSONDecoder().decode(RadarConfig.self, from: data)
    else {
      return .fallback
    }
    return config
  }
}
