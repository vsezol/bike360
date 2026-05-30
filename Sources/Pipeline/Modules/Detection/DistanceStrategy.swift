import CoreGraphics
import Foundation

// Pluggable distance estimation. Each method (ground-plane, pinhole, …) is a
// strategy behind one protocol; a coordinator picks the one whose estimate
// falls in its configured range. Adding a method = new strategy type + a line
// in distance-config.json — no branching in YoloModule.

// Everything a strategy needs to estimate distance for one detection.
public struct DistanceContext: Sendable {
  public let bbox: CGRect            // normalized, top-left origin
  public let intrinsics: CameraIntrinsics
  public let tilePitchDegrees: Float
  public let classHeightMeters: Float
  public let cameraHeightMeters: Float

  public init(
    bbox: CGRect,
    intrinsics: CameraIntrinsics,
    tilePitchDegrees: Float,
    classHeightMeters: Float,
    cameraHeightMeters: Float
  ) {
    self.bbox = bbox
    self.intrinsics = intrinsics
    self.tilePitchDegrees = tilePitchDegrees
    self.classHeightMeters = classHeightMeters
    self.cameraHeightMeters = cameraHeightMeters
  }
}

// One distance-estimation method.
public protocol DistanceStrategy: Sendable {
  var name: String { get }
  var isEnabled: Bool { get }
  // The distance band this strategy is trusted for; the coordinator only
  // accepts an estimate that lands inside it.
  var rangeMeters: ClosedRange<Float> { get }
  // Estimate distance, or nil if this strategy can't produce one for the input.
  func estimate(_ context: DistanceContext) -> Float?
}

// Ground-plane: the object stands on the road; the bbox bottom edge is its
// contact point. Depression angle φ below the optical axis gives the
// horizontal distance directly: distance = cameraHeight / tan(φ). Independent
// of the object's class/height. Accurate up close, noisy near the horizon.
public struct GroundPlaneStrategy: DistanceStrategy {
  public let name = "groundPlane"
  public let isEnabled: Bool
  public let rangeMeters: ClosedRange<Float>

  public init(isEnabled: Bool, rangeMeters: ClosedRange<Float>) {
    self.isEnabled = isEnabled
    self.rangeMeters = rangeMeters
  }

  public func estimate(_ ctx: DistanceContext) -> Float? {
    let bottomYPx = Float(ctx.bbox.maxY) * Float(ctx.intrinsics.imageHeight)
    let dyBottom = (bottomYPx - ctx.intrinsics.principalPointY) / ctx.intrinsics.focalLengthY
    let depression = atan(dyBottom) - ctx.tilePitchDegrees * .pi / 180
    guard depression > 0.0001 else { return nil }  // at/above horizon → undefined
    return ctx.cameraHeightMeters / tan(depression)
  }
}

// Pinhole height: distance = realHeight × focal / bboxHeightPx. Depends on a
// correct class height, so we CAP the assumed height (a van mislabeled "truck"
// shouldn't inherit 3.5 m). Used for far range where ground-plane is noisy.
public struct PinholeStrategy: DistanceStrategy {
  public let name = "pinhole"
  public let isEnabled: Bool
  public let rangeMeters: ClosedRange<Float>
  public let maxHeightCapMeters: Float

  public init(isEnabled: Bool, rangeMeters: ClosedRange<Float>, maxHeightCapMeters: Float) {
    self.isEnabled = isEnabled
    self.rangeMeters = rangeMeters
    self.maxHeightCapMeters = maxHeightCapMeters
  }

  public func estimate(_ ctx: DistanceContext) -> Float? {
    let bboxHeightPx = Float(ctx.bbox.height) * Float(ctx.intrinsics.imageHeight)
    guard bboxHeightPx > 0 else { return nil }
    let height = min(ctx.classHeightMeters, maxHeightCapMeters)
    return height * ctx.intrinsics.focalLengthY / bboxHeightPx
  }
}

// Picks among strategies in order: the first enabled one whose estimate lands
// in its own range wins. If none match a range, the last enabled strategy's
// estimate is used as a fallback so every detection still gets a distance.
public struct DistanceEstimator: Sendable {
  public let strategies: [DistanceStrategy]
  public let cameraHeightMeters: Float

  public init(strategies: [DistanceStrategy], cameraHeightMeters: Float) {
    self.strategies = strategies
    self.cameraHeightMeters = cameraHeightMeters
  }

  public func estimate(
    bbox: CGRect,
    intrinsics: CameraIntrinsics,
    tilePitchDegrees: Float,
    classHeightMeters: Float
  ) -> Float? {
    let ctx = DistanceContext(
      bbox: bbox,
      intrinsics: intrinsics,
      tilePitchDegrees: tilePitchDegrees,
      classHeightMeters: classHeightMeters,
      cameraHeightMeters: cameraHeightMeters
    )
    let enabled = strategies.filter(\.isEnabled)
    var fallback: Float?
    for strategy in enabled {
      guard let estimate = strategy.estimate(ctx) else { continue }
      fallback = estimate  // remember the last valid estimate
      if strategy.rangeMeters.contains(estimate) {
        return estimate
      }
    }
    return fallback
  }
}

extension DistanceEstimator {
  // Used when no distance-config.json is supplied (batch/extract). Mirrors the
  // shipped config: ground-plane up close, capped pinhole far away.
  public static let `default` = DistanceEstimator(
    strategies: [
      GroundPlaneStrategy(isEnabled: true, rangeMeters: 0...40),
      PinholeStrategy(isEnabled: true, rangeMeters: 40...80, maxHeightCapMeters: 2.0),
    ],
    cameraHeightMeters: 1.0
  )
}
