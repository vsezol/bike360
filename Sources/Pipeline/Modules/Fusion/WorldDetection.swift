import Foundation

// A detection lifted into the bike's frame of reference. Multiple per-tile
// detections of the same physical object are merged into one of these
// during Polar NMS in SpatialFusionModule. Stage 4 (3D map) and beyond
// consume these directly — they no longer carry tile or lens-specific
// geometry, just "object at this direction and distance from the bike".
public struct WorldDetection: Sendable, Hashable {
  public let classLabel: String
  public let confidence: Float

  // Direction from the bike, in bike-frame degrees.
  // yaw:  0 = forward, +90 = right, ±180 = behind, -90 = left.
  // pitch: 0 = horizon, positive = above horizon.
  public let yawInBikeDegrees: Float
  public let pitchInBikeDegrees: Float

  public let estimatedDistanceMeters: Float

  // Which lens(es) contributed to this fused detection. After a successful
  // cross-tile merge a single object can have both .front and .back here
  // (rare but possible at the 90°/270° seam).
  public let contributingLenses: Set<Lens>

  // How many raw tile-level detections were folded into this one. ≥ 1.
  public let mergedDetectionCount: Int

  public init(
    classLabel: String,
    confidence: Float,
    yawInBikeDegrees: Float,
    pitchInBikeDegrees: Float,
    estimatedDistanceMeters: Float,
    contributingLenses: Set<Lens>,
    mergedDetectionCount: Int
  ) {
    self.classLabel = classLabel
    self.confidence = confidence
    self.yawInBikeDegrees = yawInBikeDegrees
    self.pitchInBikeDegrees = pitchInBikeDegrees
    self.estimatedDistanceMeters = estimatedDistanceMeters
    self.contributingLenses = contributingLenses
    self.mergedDetectionCount = mergedDetectionCount
  }
}
