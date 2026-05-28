import Foundation

// Object classes we care about for motorcycle safety. The full COCO set has
// 80 classes; the rest (sofa, banana, giraffe…) are filtered out during
// post-processing so they never pollute the detection stream.
//
// Each class carries an approximate real-world height in meters. Distance
// is estimated via the pinhole formula:
//
//     distance ≈ (realHeightMeters × focalLengthPixels) / bboxHeightPixels
//
// Height is used (not length) because it stays roughly constant across
// viewing angles — a car is ~1.5m tall whether you see it from front,
// back, or side. Length varies 2–3× depending on orientation.
public enum DetectionClass: String, Sendable, Hashable, CaseIterable {
  case person
  case bicycle
  case car
  case motorcycle
  case bus
  case truck
  case trafficLight = "traffic light"
  case stopSign = "stop sign"

  public var realWorldHeightMeters: Float {
    switch self {
    case .person: return 1.70
    case .bicycle: return 1.10
    case .car: return 1.50
    case .motorcycle: return 1.20
    case .bus: return 3.20
    case .truck: return 3.50
    case .trafficLight: return 0.90
    case .stopSign: return 0.75
    }
  }

  // Initialise from a YOLO label string. Returns nil for any class we don't
  // track (sofa, banana, etc.) — those get filtered out at the boundary.
  public init?(yoloLabel: String) {
    self.init(rawValue: yoloLabel.lowercased())
  }
}
