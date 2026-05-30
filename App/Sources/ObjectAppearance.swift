import SceneKit
import UIKit
import Pipeline

// Maps a tracked object's class to its 3D appearance: a box sized to the
// real-world footprint from DetectionConfig (width × height × length, in
// meters), plus a color. Unknown classes fall back to a small gray cube.
//
// Box axes follow SceneKit: width = X (across), height = Y (up),
// length = Z (along the object's travel). The same proportions will later
// drive real 3D models swapped in per class.
struct ObjectAppearance {
  let config: DetectionConfig

  func boxSize(for classLabel: String) -> SCNVector3 {
    guard let info = config.info(for: classLabel) else {
      return SCNVector3(0.5, 0.5, 0.5)
    }
    return SCNVector3(info.widthMeters, info.heightMeters, info.lengthMeters)
  }

  func color(for classLabel: String) -> UIColor {
    let name = config.info(for: classLabel)?.colorName ?? "white"
    return Self.uiColor(named: name)
  }

  // Same named palette the CLI overlay uses, so colors are consistent
  // between the debug PNGs and the 3D map.
  static func uiColor(named name: String) -> UIColor {
    switch name.lowercased() {
    case "red":     return UIColor(red: 1.00, green: 0.25, blue: 0.25, alpha: 1)
    case "green":   return UIColor(red: 0.20, green: 0.85, blue: 0.20, alpha: 1)
    case "blue":    return UIColor(red: 0.20, green: 0.50, blue: 1.00, alpha: 1)
    case "orange":  return UIColor(red: 1.00, green: 0.60, blue: 0.10, alpha: 1)
    case "yellow":  return UIColor(red: 1.00, green: 1.00, blue: 0.30, alpha: 1)
    case "cyan":    return UIColor(red: 0.20, green: 0.85, blue: 1.00, alpha: 1)
    case "magenta": return UIColor(red: 1.00, green: 0.30, blue: 0.80, alpha: 1)
    default:        return .white
    }
  }
}
