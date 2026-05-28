import Foundation

// Per-class metadata used by YoloModule (distance estimation) and by the
// CLI overlay drawer (bbox colors). Loaded from a JSON file at startup so
// you can tweak heights / add classes without recompiling.
//
// JSON format:
//   {
//     "car":     { "heightMeters": 1.50, "color": "green" },
//     "person":  { "heightMeters": 1.70, "color": "red"   },
//     ...
//   }
//
// Keys must match the YOLO model's label strings exactly (lowercased).
// Anything the YOLO model returns that's NOT in this map is filtered out —
// this is what restricts COCO 80 to our traffic-relevant subset.
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

  public func info(for yoloLabel: String) -> ClassInfo? {
    classes[yoloLabel.lowercased()]
  }

  public static let `default` = DetectionConfig(classes: [
    "person":         ClassInfo(heightMeters: 1.70, colorName: "red"),
    "bicycle":        ClassInfo(heightMeters: 1.10, colorName: "orange"),
    "car":            ClassInfo(heightMeters: 1.50, colorName: "green"),
    "motorcycle":     ClassInfo(heightMeters: 1.20, colorName: "orange"),
    "bus":            ClassInfo(heightMeters: 3.20, colorName: "blue"),
    "truck":          ClassInfo(heightMeters: 3.50, colorName: "blue"),
    "traffic light":  ClassInfo(heightMeters: 0.90, colorName: "yellow"),
    "stop sign":      ClassInfo(heightMeters: 0.75, colorName: "red"),
  ])

  public static func load(from url: URL) throws -> DetectionConfig {
    let data = try Data(contentsOf: url)
    let dict = try JSONDecoder().decode([String: RawClassInfo].self, from: data)
    let normalized = dict.reduce(into: [String: ClassInfo]()) { result, pair in
      result[pair.key.lowercased()] = ClassInfo(
        heightMeters: pair.value.heightMeters,
        colorName: pair.value.color
      )
    }
    return DetectionConfig(classes: normalized)
  }

  private struct RawClassInfo: Decodable {
    let heightMeters: Float
    let color: String
  }
}
