import CoreMedia
import Foundation

// Output of TrackingModule. Carries a stable identity (trackId) plus a
// smoothed class — robust to per-frame YOLO jitter — and velocity in the
// bike's polar frame so downstream UI can mark objects as "approaching",
// "receding", or "overtaking".
public struct TrackedObject: Sendable, Hashable {
  public let trackId: UInt64
  // Smoothed class label, voted from the last N matched detections of
  // this track weighted by confidence. Won't flip mid-track unless the
  // model is consistently wrong for several frames in a row.
  public let classLabel: String
  // Smoothed confidence: highest confidence the class received in its
  // recent history, attenuated by votes for competing classes.
  public let classConfidence: Float

  public let yawInBikeDegrees: Float
  public let pitchInBikeDegrees: Float
  public let estimatedDistanceMeters: Float

  // Angular velocity around the rider (degrees per second). Positive =
  // moving to the right of the bike, negative = to the left. Useful for
  // "is this overtaking on my left?" alerts.
  public let angularVelocityDegPerSec: Float
  // Radial velocity (meters per second). Negative = approaching.
  public let radialVelocityMetersPerSec: Float

  public let ageFrames: Int
  // True after the track has been matched for N consecutive frames —
  // crisp signal that this isn't a one-frame phantom from YOLO noise.
  public let isReliable: Bool

  public init(
    trackId: UInt64,
    classLabel: String,
    classConfidence: Float,
    yawInBikeDegrees: Float,
    pitchInBikeDegrees: Float,
    estimatedDistanceMeters: Float,
    angularVelocityDegPerSec: Float,
    radialVelocityMetersPerSec: Float,
    ageFrames: Int,
    isReliable: Bool
  ) {
    self.trackId = trackId
    self.classLabel = classLabel
    self.classConfidence = classConfidence
    self.yawInBikeDegrees = yawInBikeDegrees
    self.pitchInBikeDegrees = pitchInBikeDegrees
    self.estimatedDistanceMeters = estimatedDistanceMeters
    self.angularVelocityDegPerSec = angularVelocityDegPerSec
    self.radialVelocityMetersPerSec = radialVelocityMetersPerSec
    self.ageFrames = ageFrames
    self.isReliable = isReliable
  }
}
