import CoreMedia
import Foundation

// ByteTrack-style multi-object tracker operating in the bike's polar frame.
//
// Per frame:
//  1. Each active track predicts where it should be now via constant-
//     velocity extrapolation on (yaw, pitch, distance).
//  2. High-confidence detections (≥ highConfidenceThreshold) are matched
//     against active tracks via greedy nearest-neighbour on a
//     polar-distance cost (angular Δ + relative distance Δ).
//  3. Low-confidence detections (< highConfidenceThreshold) are matched
//     against tracks that didn't get a high-conf match — this is the
//     ByteTrack idea: keep tracks alive through brief low-confidence
//     spells (partial occlusion, motion blur) without spawning ghost IDs.
//  4. Unmatched high-conf detections spawn new tracks. Unmatched tracks
//     age into "lost"; after maxLostFrames they're removed.
//  5. Each match feeds the track's (class, confidence) history; the
//     output classLabel is a confidence-weighted vote over the last N
//     of those, which is what kills the truck↔car jitter.
//
// Stateful: held across frames inside an actor so it's safe to drive
// from the pipeline.
public actor TrackingModule: PipelineModule {
  public typealias Input = TrackingInput
  public typealias Output = [TrackedObject]

  public struct Settings: Sendable {
    public var highConfidenceThreshold: Float
    // Maximum polar cost for a match. Cost = angular° + 50 * relativeDistanceΔ.
    // E.g. cost 10 ≈ 10° apart at same distance, or 5° apart with 10% Δ.
    public var maxMatchCost: Float
    // How many consecutive missed frames before a track is removed.
    public var maxLostFrames: Int
    // Frames before a track is marked "reliable" (and shown to user).
    public var reliabilityThreshold: Int
    // Window for class-vote smoothing. Larger = more inertia.
    public var classHistoryWindow: Int
    // Exponential smoothing factor for velocity estimates [0..1].
    // 0.3 — moderate inertia, suitable for ~30 fps.
    public var velocitySmoothing: Float
    // How many missed frames a track may still be EMITTED for. Tracks are
    // kept internally up to maxLostFrames for re-matching, but emitting a
    // track that hasn't matched for many frames draws a ghost next to the
    // object that already moved on — a visible duplicate. A small grace
    // (1–2) survives a single dropped detection without flicker.
    public var displayGraceFrames: Int

    public init(
      highConfidenceThreshold: Float = 0.5,
      maxMatchCost: Float = 12.0,
      maxLostFrames: Int = 10,
      reliabilityThreshold: Int = 3,
      classHistoryWindow: Int = 10,
      velocitySmoothing: Float = 0.3,
      displayGraceFrames: Int = 2
    ) {
      self.highConfidenceThreshold = highConfidenceThreshold
      self.maxMatchCost = maxMatchCost
      self.maxLostFrames = maxLostFrames
      self.reliabilityThreshold = reliabilityThreshold
      self.classHistoryWindow = classHistoryWindow
      self.velocitySmoothing = velocitySmoothing
      self.displayGraceFrames = displayGraceFrames
    }

    public static let `default` = Settings()
  }

  // Per-track mutable state. Kept private to the actor.
  private struct TrackState {
    let trackId: UInt64
    var classHistory: [(label: String, confidence: Float)]
    var yawDegrees: Float
    var pitchDegrees: Float
    var distanceMeters: Float
    var yawVelocityDegPerSec: Float
    var pitchVelocityDegPerSec: Float
    var distanceVelocityMPerSec: Float
    var lastSeenTimestamp: CMTime
    var ageFrames: Int
    var framesSinceLastMatch: Int

    var isLost: Bool { framesSinceLastMatch > 0 }
  }

  private let settings: Settings
  private var tracks: [TrackState] = []
  private var nextTrackId: UInt64 = 1
  private var lastFrameTimestamp: CMTime?

  public init(settings: Settings = .default) {
    self.settings = settings
  }

  public func process(_ input: TrackingInput) async throws -> [TrackedObject] {
    let now = input.frameTimestamp
    let dt = lastFrameTimestamp.map { Float(CMTimeGetSeconds(now - $0)) } ?? 0
    lastFrameTimestamp = now

    // 1. Predict where each existing track should be now.
    if dt > 0 {
      for i in 0..<tracks.count {
        tracks[i].yawDegrees = wrapYaw(tracks[i].yawDegrees + tracks[i].yawVelocityDegPerSec * dt)
        tracks[i].pitchDegrees += tracks[i].pitchVelocityDegPerSec * dt
        // Clamp: a lost, approaching track must not extrapolate through 0
        // into negative distance (which then renders behind the rider).
        tracks[i].distanceMeters = max(0.1, tracks[i].distanceMeters + tracks[i].distanceVelocityMPerSec * dt)
      }
    }

    // 2. Split detections by confidence.
    let highConf = input.detections.filter { $0.confidence >= settings.highConfidenceThreshold }
    let lowConf = input.detections.filter { $0.confidence < settings.highConfidenceThreshold }

    // 3. First association — high-confidence detections vs all tracks.
    var unmatchedTrackIdxs = Set(tracks.indices)
    var unmatchedHighConf: [WorldDetection] = []
    for detection in highConf {
      if let (idx, _) = bestTrack(for: detection, among: unmatchedTrackIdxs) {
        applyMatch(trackIdx: idx, detection: detection, dt: dt, timestamp: now)
        unmatchedTrackIdxs.remove(idx)
      } else {
        unmatchedHighConf.append(detection)
      }
    }

    // 4. Second association — low-confidence detections vs leftover tracks.
    for detection in lowConf {
      guard let (idx, _) = bestTrack(for: detection, among: unmatchedTrackIdxs) else { continue }
      applyMatch(trackIdx: idx, detection: detection, dt: dt, timestamp: now)
      unmatchedTrackIdxs.remove(idx)
    }

    // 5. Spawn new tracks for unmatched high-confidence detections.
    for detection in unmatchedHighConf {
      let id = nextTrackId
      nextTrackId += 1
      tracks.append(TrackState(
        trackId: id,
        classHistory: [(detection.classLabel, detection.confidence)],
        yawDegrees: detection.yawInBikeDegrees,
        pitchDegrees: detection.pitchInBikeDegrees,
        distanceMeters: detection.estimatedDistanceMeters,
        yawVelocityDegPerSec: 0,
        pitchVelocityDegPerSec: 0,
        distanceVelocityMPerSec: 0,
        lastSeenTimestamp: now,
        ageFrames: 1,
        framesSinceLastMatch: 0
      ))
    }

    // 6. Age unmatched tracks; drop ones lost beyond the budget.
    for idx in unmatchedTrackIdxs {
      tracks[idx].framesSinceLastMatch += 1
      tracks[idx].ageFrames += 1
    }
    tracks.removeAll { $0.framesSinceLastMatch > settings.maxLostFrames }

    // 7. Emit only recently-seen tracks. Lost tracks live on internally (up
    // to maxLostFrames) so a returning object re-matches its old id, but we
    // don't DRAW a track that's been missing for more than displayGraceFrames
    // — that ghost is what duplicates a moved object on screen.
    return tracks
      .filter { $0.framesSinceLastMatch <= settings.displayGraceFrames }
      .map(makeTrackedObject)
  }

  // MARK: - Matching helpers

  // Greedy nearest-neighbour. Returns the lowest-cost track within the
  // configured cost threshold and class constraint, plus the cost.
  private func bestTrack(
    for detection: WorldDetection,
    among trackIdxs: Set<Int>
  ) -> (Int, Float)? {
    var bestIdx: Int?
    var bestCost = Float.infinity
    for idx in trackIdxs {
      let cost = matchCost(track: tracks[idx], detection: detection)
      if cost < bestCost {
        bestCost = cost
        bestIdx = idx
      }
    }
    guard let idx = bestIdx, bestCost <= settings.maxMatchCost else { return nil }
    return (idx, bestCost)
  }

  // Cost = angular distance (degrees) + 50 * relative distance Δ.
  // Same-class is enforced by the smoothed class label — if the track's
  // smoothed class disagrees AND the detection's class isn't in the
  // history, we reject the match outright.
  private func matchCost(track: TrackState, detection: WorldDetection) -> Float {
    let smoothedClass = Self.smoothedClassLabel(history: track.classHistory)
    let detectionInHistory = track.classHistory.contains { $0.label == detection.classLabel }
    if smoothedClass != detection.classLabel && !detectionInHistory {
      return .infinity
    }

    let angular = angularDistanceDegrees(
      yaw1: track.yawDegrees, pitch1: track.pitchDegrees,
      yaw2: detection.yawInBikeDegrees, pitch2: detection.pitchInBikeDegrees
    )
    let distRatio = abs(track.distanceMeters - detection.estimatedDistanceMeters)
      / max(track.distanceMeters, detection.estimatedDistanceMeters, 0.01)
    return angular + 50 * distRatio
  }

  private func applyMatch(
    trackIdx: Int,
    detection: WorldDetection,
    dt: Float,
    timestamp: CMTime
  ) {
    var track = tracks[trackIdx]
    // Velocity update via exponential smoothing on the raw delta-per-second.
    if dt > 0 {
      let yawDelta = shortestSignedYawDeltaDegrees(
        from: track.yawDegrees, to: detection.yawInBikeDegrees
      )
      let pitchDelta = detection.pitchInBikeDegrees - track.pitchDegrees
      let distanceDelta = detection.estimatedDistanceMeters - track.distanceMeters
      let alpha = settings.velocitySmoothing
      track.yawVelocityDegPerSec = (1 - alpha) * track.yawVelocityDegPerSec + alpha * (yawDelta / dt)
      track.pitchVelocityDegPerSec = (1 - alpha) * track.pitchVelocityDegPerSec + alpha * (pitchDelta / dt)
      track.distanceVelocityMPerSec = (1 - alpha) * track.distanceVelocityMPerSec + alpha * (distanceDelta / dt)
    }
    track.yawDegrees = detection.yawInBikeDegrees
    track.pitchDegrees = detection.pitchInBikeDegrees
    track.distanceMeters = detection.estimatedDistanceMeters

    track.classHistory.append((detection.classLabel, detection.confidence))
    if track.classHistory.count > settings.classHistoryWindow {
      track.classHistory.removeFirst(track.classHistory.count - settings.classHistoryWindow)
    }

    track.lastSeenTimestamp = timestamp
    track.framesSinceLastMatch = 0
    track.ageFrames += 1

    tracks[trackIdx] = track
  }

  private func makeTrackedObject(_ track: TrackState) -> TrackedObject {
    let smoothed = Self.smoothedClassLabel(history: track.classHistory)
    let smoothedConfidence = Self.smoothedConfidence(history: track.classHistory, for: smoothed)
    return TrackedObject(
      trackId: track.trackId,
      classLabel: smoothed,
      classConfidence: smoothedConfidence,
      yawInBikeDegrees: track.yawDegrees,
      pitchInBikeDegrees: track.pitchDegrees,
      estimatedDistanceMeters: track.distanceMeters,
      angularVelocityDegPerSec: track.yawVelocityDegPerSec,
      radialVelocityMetersPerSec: track.distanceVelocityMPerSec,
      ageFrames: track.ageFrames,
      isReliable: track.ageFrames >= settings.reliabilityThreshold
    )
  }

  // MARK: - Class smoothing

  // Confidence-weighted vote: each (class, confidence) is summed per class,
  // winner is the highest-summed class. Beats a simple majority when the
  // history is split because confident detections outweigh weak ones.
  private static func smoothedClassLabel(history: [(label: String, confidence: Float)]) -> String {
    var scores: [String: Float] = [:]
    for entry in history {
      scores[entry.label, default: 0] += entry.confidence
    }
    return scores.max(by: { $0.value < $1.value })?.key ?? history.last?.label ?? ""
  }

  private static func smoothedConfidence(
    history: [(label: String, confidence: Float)],
    for label: String
  ) -> Float {
    let matching = history.filter { $0.label == label }
    guard !matching.isEmpty else { return 0 }
    let total = matching.reduce(Float(0)) { $0 + $1.confidence }
    return total / Float(matching.count)
  }

  // MARK: - Geometry helpers (duplicated locally to keep module self-contained)

  private func angularDistanceDegrees(
    yaw1: Float, pitch1: Float, yaw2: Float, pitch2: Float
  ) -> Float {
    let v1 = unitVector(yawDegrees: yaw1, pitchDegrees: pitch1)
    let v2 = unitVector(yawDegrees: yaw2, pitchDegrees: pitch2)
    let dot = max(-1.0, min(1.0, v1.x * v2.x + v1.y * v2.y + v1.z * v2.z))
    return acos(dot) * 180.0 / .pi
  }

  private func unitVector(yawDegrees: Float, pitchDegrees: Float) -> (x: Float, y: Float, z: Float) {
    let yaw = yawDegrees * .pi / 180
    let pitch = pitchDegrees * .pi / 180
    let cosP = cos(pitch)
    return (cosP * sin(yaw), sin(pitch), cosP * cos(yaw))
  }

  private func wrapYaw(_ yaw: Float) -> Float {
    var y = yaw.truncatingRemainder(dividingBy: 360)
    if y > 180 { y -= 360 }
    if y <= -180 { y += 360 }
    return y
  }

  // Shortest signed delta on the circle, useful for velocity around the
  // ±180° seam (object crossing directly behind the rider).
  private func shortestSignedYawDeltaDegrees(from: Float, to: Float) -> Float {
    var d = to - from
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return d
  }
}

public struct TrackingInput: Sendable {
  public let detections: [WorldDetection]
  public let frameTimestamp: CMTime
  public let frameNumber: UInt64

  public init(detections: [WorldDetection], frameTimestamp: CMTime, frameNumber: UInt64) {
    self.detections = detections
    self.frameTimestamp = frameTimestamp
    self.frameNumber = frameNumber
  }
}
