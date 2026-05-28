import CoreGraphics
import Foundation

// One detected object on one tile, already lifted from raw YOLO output into
// the geometry the rest of the system speaks in:
//
//  - Angular position relative to the lens optical axis (yaw + pitch).
//    Stage 3 will combine this with helmet and bike gyro to place the
//    object in bike-frame world coordinates.
//
//  - Estimated distance in meters, from the class' known real-world height
//    and the bbox height in pixels.
//
//  - Source tile metadata for traceability and cross-tile NMS.
public struct Detection: Sendable, Hashable {
  public let objectClass: DetectionClass
  public let confidence: Float
  // Normalized bbox in tile coords. (0,0) top-left, (1,1) bottom-right.
  public let bbox: CGRect
  // Angular position in lens space (lens optical axis = 0,0).
  // yaw: positive = right of axis, negative = left.
  // pitch: positive = above horizon, negative = below.
  public let yawInLensDegrees: Float
  public let pitchInLensDegrees: Float
  // Estimated distance in meters via the pinhole height formula.
  public let estimatedDistanceMeters: Float
  // Which lens this came from.
  public let lens: Lens
  // Tile origin metadata — useful for debugging and cross-tile NMS.
  public let sourceTileYawDegrees: Float
  public let sourceTilePitchDegrees: Float

  public init(
    objectClass: DetectionClass,
    confidence: Float,
    bbox: CGRect,
    yawInLensDegrees: Float,
    pitchInLensDegrees: Float,
    estimatedDistanceMeters: Float,
    lens: Lens,
    sourceTileYawDegrees: Float,
    sourceTilePitchDegrees: Float
  ) {
    self.objectClass = objectClass
    self.confidence = confidence
    self.bbox = bbox
    self.yawInLensDegrees = yawInLensDegrees
    self.pitchInLensDegrees = pitchInLensDegrees
    self.estimatedDistanceMeters = estimatedDistanceMeters
    self.lens = lens
    self.sourceTileYawDegrees = sourceTileYawDegrees
    self.sourceTilePitchDegrees = sourceTilePitchDegrees
  }
}

// All detections from one stereo frame, ready to feed into stage 3 (3D map).
public struct StereoDetections: Sendable {
  public let detections: [Detection]
  public let sequenceNumber: UInt64

  public init(detections: [Detection], sequenceNumber: UInt64) {
    self.detections = detections
    self.sequenceNumber = sequenceNumber
  }

  public func detections(for lens: Lens) -> [Detection] {
    detections.filter { $0.lens == lens }
  }
}
