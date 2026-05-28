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
//     "car":          { "heightMeters": 1.50, "color": "green" },
//     "trafficLight": { "heightMeters": 0.90, "color": "yellow" },
//     ...
//   }
//
// Anything the YOLO model returns that's NOT in this map is filtered out —
// this restricts COCO 80 to our traffic-relevant subset.
public struct DetectionConfig: Sendable {
  public struct ClassInfo: Sendable, Hashable {
    public let heightMeters: Float
    public let colorName: String

    public init(heightMeters: Float, colorName: String) {
      self.heightMeters = heightMeters
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
        colorName: pair.value.color
      )
    }
    return DetectionConfig(classes: mapped)
  }

  private struct RawClassInfo: Decodable {
    let heightMeters: Float
    let color: String
  }
}
