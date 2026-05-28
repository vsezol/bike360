import Foundation

// Stage 3 step (b): lift per-tile Detections into bike-frame WorldDetections
// and merge cross-tile duplicates via Polar NMS.
//
// Step 1 — coordinate transform.
//   Each Detection lives in lens space (angles relative to that lens's
//   optical axis). To get to bike space we compose three rotations:
//
//     yawInBike   = yawInLens + lensOffsetInHelmet
//                              + helmet.yaw - bike.yaw
//     pitchInBike = pitchInLens + helmet.pitch - bike.pitch
//
//   lensOffsetInHelmet is +0° for the front lens, +180° for the back lens.
//   Mock sources zero out helmet and bike, so for the immediate next step
//   "yawInBike" is essentially "yawInLens + lensOffset". When real gyros
//   arrive at stage 3d/e this transform becomes the actual head/bike comp.
//
// Step 2 — Polar NMS.
//   Two raw detections from different tiles can be the same physical
//   object that fell into both overlap zones. We pair-test every detection
//   against every other, link them when they are close enough in
//   (angular direction, metric distance) AND share a class, then merge
//   each connected component into a single WorldDetection.
public final class SpatialFusionModule: PipelineModule, Sendable {
  public typealias Input = SpatialFusionInput
  public typealias Output = [WorldDetection]

  public struct Settings: Sendable {
    // Angular distance between two detections under which they're
    // considered "same direction" (degrees on the unit sphere).
    public var angularMergeThresholdDegrees: Float
    // Relative distance difference under which they're considered "same
    // depth". 0.30 means within 30% of each other.
    public var distanceRatioThreshold: Float
    // Treat both lenses' detections as overlapping at the seams (90°,
    // -90° in bike frame). If false, front-only objects can't merge with
    // back-only objects even if their world angle happens to coincide.
    public var allowCrossLensMerge: Bool

    public init(
      angularMergeThresholdDegrees: Float = 5.0,
      distanceRatioThreshold: Float = 0.30,
      allowCrossLensMerge: Bool = true
    ) {
      self.angularMergeThresholdDegrees = angularMergeThresholdDegrees
      self.distanceRatioThreshold = distanceRatioThreshold
      self.allowCrossLensMerge = allowCrossLensMerge
    }

    public static let `default` = Settings()
  }

  private let settings: Settings

  public init(settings: Settings = .default) {
    self.settings = settings
  }

  public func process(_ input: SpatialFusionInput) async throws -> [WorldDetection] {
    // 1. Transform every detection to bike frame.
    let lifted = input.detections.map { detection in
      Self.liftToBikeFrame(
        detection: detection,
        helmet: input.helmetOrientation,
        bike: input.bikeOrientation
      )
    }

    // 2. Polar NMS via union-find on a same-object adjacency graph.
    return mergeOverlapping(lifted)
  }

  // MARK: - Step 1: coordinate transform

  // Internal carrier used between the transform and the NMS step.
  private struct LiftedDetection {
    let classLabel: String
    let confidence: Float
    let yawInBike: Float
    let pitchInBike: Float
    let distance: Float
    let lens: Lens
  }

  private static func liftToBikeFrame(
    detection: Detection,
    helmet: Orientation,
    bike: Orientation
  ) -> LiftedDetection {
    let lensOffset: Float = detection.lens == .front ? 0 : 180

    let yawInBike = normalizeYaw(
      detection.yawInLensDegrees
        + lensOffset
        + helmet.yawDegrees
        - bike.yawDegrees
    )
    let pitchInBike =
      detection.pitchInLensDegrees
      + helmet.pitchDegrees
      - bike.pitchDegrees

    return LiftedDetection(
      classLabel: detection.classLabel,
      confidence: detection.confidence,
      yawInBike: yawInBike,
      pitchInBike: pitchInBike,
      distance: detection.estimatedDistanceMeters,
      lens: detection.lens
    )
  }

  // Wrap yaw into (-180, +180].
  private static func normalizeYaw(_ yaw: Float) -> Float {
    var y = yaw.truncatingRemainder(dividingBy: 360)
    if y > 180 { y -= 360 }
    if y <= -180 { y += 360 }
    return y
  }

  // MARK: - Step 2: Polar NMS via union-find

  private func mergeOverlapping(_ lifted: [LiftedDetection]) -> [WorldDetection] {
    let n = lifted.count
    guard n > 0 else { return [] }

    var uf = UnionFind(count: n)
    let angularThreshold = settings.angularMergeThresholdDegrees

    for i in 0..<n {
      for j in (i + 1)..<n {
        let a = lifted[i]
        let b = lifted[j]

        if a.classLabel != b.classLabel { continue }
        if !settings.allowCrossLensMerge && a.lens != b.lens { continue }

        let angDist = Self.angularDistanceDegrees(
          yaw1: a.yawInBike, pitch1: a.pitchInBike,
          yaw2: b.yawInBike, pitch2: b.pitchInBike
        )
        if angDist > angularThreshold { continue }

        let dRatio = abs(a.distance - b.distance) / max(a.distance, b.distance)
        if dRatio > settings.distanceRatioThreshold { continue }

        uf.union(i, j)
      }
    }

    // Bucket detections by their union-find root, then collapse each
    // bucket into a single WorldDetection.
    var groups: [Int: [LiftedDetection]] = [:]
    for i in 0..<n {
      let root = uf.find(i)
      groups[root, default: []].append(lifted[i])
    }

    return groups.values.map { Self.mergeGroup($0) }
  }

  // Angular distance on the unit sphere via 3D dot product. Exact and
  // wrap-safe — works even if one detection is at yaw=+179 and another
  // at yaw=-179 (they're 2° apart, not 358°).
  private static func angularDistanceDegrees(
    yaw1: Float, pitch1: Float,
    yaw2: Float, pitch2: Float
  ) -> Float {
    let v1 = unitVector(yawDegrees: yaw1, pitchDegrees: pitch1)
    let v2 = unitVector(yawDegrees: yaw2, pitchDegrees: pitch2)
    let dot = max(-1.0, min(1.0, v1.x * v2.x + v1.y * v2.y + v1.z * v2.z))
    return acos(dot) * 180.0 / .pi
  }

  private static func unitVector(yawDegrees: Float, pitchDegrees: Float) -> (x: Float, y: Float, z: Float) {
    let yaw = yawDegrees * .pi / 180
    let pitch = pitchDegrees * .pi / 180
    // Convention: x = right, y = up, z = forward.
    let cosP = cos(pitch)
    return (cosP * sin(yaw), sin(pitch), cosP * cos(yaw))
  }

  // Confidence-weighted average for direction + distance; max for
  // confidence; union of lens contributions; count = group size.
  private static func mergeGroup(_ group: [LiftedDetection]) -> WorldDetection {
    let totalConfidence = group.reduce(Float(0)) { $0 + $1.confidence }
    let weights = group.map { $0.confidence / totalConfidence }

    var yawSum: Float = 0
    var pitchSum: Float = 0
    var distSum: Float = 0
    var maxConf: Float = 0
    var lenses: Set<Lens> = []
    for (i, item) in group.enumerated() {
      yawSum += item.yawInBike * weights[i]
      pitchSum += item.pitchInBike * weights[i]
      distSum += item.distance * weights[i]
      if item.confidence > maxConf { maxConf = item.confidence }
      lenses.insert(item.lens)
    }

    return WorldDetection(
      classLabel: group[0].classLabel,
      confidence: maxConf,
      yawInBikeDegrees: yawSum,
      pitchInBikeDegrees: pitchSum,
      estimatedDistanceMeters: distSum,
      contributingLenses: lenses,
      mergedDetectionCount: group.count
    )
  }
}

// Input bundle: combined per-tile detections + the two orientation
// snapshots that apply to this stereo frame.
public struct SpatialFusionInput: Sendable {
  public let detections: [Detection]
  public let helmetOrientation: Orientation
  public let bikeOrientation: Orientation

  public init(
    detections: [Detection],
    helmetOrientation: Orientation,
    bikeOrientation: Orientation
  ) {
    self.detections = detections
    self.helmetOrientation = helmetOrientation
    self.bikeOrientation = bikeOrientation
  }
}

// Simple union-find for connected-component grouping during NMS.
private struct UnionFind {
  private var parent: [Int]
  private var rank: [Int]

  init(count: Int) {
    parent = Array(0..<count)
    rank = Array(repeating: 0, count: count)
  }

  mutating func find(_ x: Int) -> Int {
    if parent[x] != x { parent[x] = find(parent[x]) }
    return parent[x]
  }

  mutating func union(_ a: Int, _ b: Int) {
    let ra = find(a), rb = find(b)
    if ra == rb { return }
    if rank[ra] < rank[rb] { parent[ra] = rb }
    else if rank[ra] > rank[rb] { parent[rb] = ra }
    else { parent[rb] = ra; rank[ra] += 1 }
  }
}
