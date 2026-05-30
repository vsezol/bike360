import Foundation

// Per-class metadata used by YoloModule (distance estimation) and by the
// CLI overlay drawer (bbox colors). Loaded from a JSON file at startup so
// heights and added classes need no recompile.
//
// JSON format (keys are camelCase so they line up with future Swift enum
// cases — YOLO's raw labels with spaces are normalized to camelCase by
// YoloModule before the lookup happens):
//
//   {
//     "car":          { "heightMeters": 1.50, "widthMeters": 1.80, "lengthMeters": 4.30, "color": "green" },
//     "trafficLight": { "heightMeters": 0.90, "widthMeters": 0.30, "lengthMeters": 0.30, "color": "yellow" },
//     ...
//   }
//
// heightMeters drives distance estimation (pinhole). width/length are the
// object's real-world footprint, used by the 3D map to size each box
// proportionally to the actual vehicle/person it represents.
//
// Anything the YOLO model returns that's NOT in this map is filtered out —
// this restricts COCO 80 to our traffic-relevant subset.
public struct DetectionConfig: Sendable {
  public struct ClassInfo: Sendable, Hashable {
    public let heightMeters: Float
    // Real-world footprint, in meters. width = across the object,
    // length = along its direction of travel. Consumed by the 3D map.
    public let widthMeters: Float
    public let lengthMeters: Float
    public let colorName: String

    public init(heightMeters: Float, widthMeters: Float, lengthMeters: Float, colorName: String) {
      self.heightMeters = heightMeters
      self.widthMeters = widthMeters
      self.lengthMeters = lengthMeters
      self.colorName = colorName
    }
  }

  public let classes: [String: ClassInfo]

  public init(classes: [String: ClassInfo]) {
    self.classes = classes
  }

  // Look up by camelCase key. YoloModule normalizes YOLO's raw label
  // ("traffic light") to camelCase ("trafficLight") before calling this.
  public func info(for camelCaseKey: String) -> ClassInfo? {
    classes[camelCaseKey]
  }

  public static func load(from url: URL) throws -> DetectionConfig {
    let data = try Data(contentsOf: url)
    let dict = try JSONDecoder().decode([String: RawClassInfo].self, from: data)
    let mapped = dict.reduce(into: [String: ClassInfo]()) { result, pair in
      result[pair.key] = ClassInfo(
        heightMeters: pair.value.heightMeters,
        widthMeters: pair.value.widthMeters,
        lengthMeters: pair.value.lengthMeters,
        colorName: pair.value.color
      )
    }
    return DetectionConfig(classes: mapped)
  }

  private struct RawClassInfo: Decodable {
    let heightMeters: Float
    let widthMeters: Float
    let lengthMeters: Float
    let color: String
  }
}
