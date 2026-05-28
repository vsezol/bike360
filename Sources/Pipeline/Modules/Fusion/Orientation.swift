import CoreMedia
import Foundation

// Absolute orientation in a world (or bike-frame) coordinate system.
// All angles in degrees. Convention used throughout the project:
//
//   yaw   — heading, around vertical axis. 0 = forward, +90 = right.
//   pitch — tilt up/down. 0 = horizon, +X = looking above horizon.
//   roll  — lean side-to-side. 0 = upright, + = leaning right.
//
// All three sources speak the same convention so transforms compose
// without sign juggling.
public struct Orientation: Sendable, Hashable {
  public let yawDegrees: Float
  public let pitchDegrees: Float
  public let rollDegrees: Float
  public let timestamp: CMTime

  public init(
    yawDegrees: Float,
    pitchDegrees: Float,
    rollDegrees: Float,
    timestamp: CMTime
  ) {
    self.yawDegrees = yawDegrees
    self.pitchDegrees = pitchDegrees
    self.rollDegrees = rollDegrees
    self.timestamp = timestamp
  }

  public static func zero(at timestamp: CMTime = .zero) -> Orientation {
    Orientation(yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0, timestamp: timestamp)
  }
}
