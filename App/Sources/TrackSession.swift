import Foundation

// Decodable mirror of the CLI's `export-track` output. One TrackSession
// holds the whole replay: an ordered list of frames, each with the tracked
// objects visible at that moment. The 3D map replays this directly.
struct TrackSession: Decodable {
  let videoPath: String
  let startFrame: Int
  let frameCount: Int
  let frames: [TrackFrame]
}

struct TrackFrame: Decodable {
  let frameNumber: Int
  let timestampSeconds: Double
  let objects: [TrackedObjectData]
}

// One tracked object in the bike's polar frame. Field names match the
// CLI's TrackedObjectDTO exactly so JSON decoding is keyless-default.
struct TrackedObjectData: Decodable, Identifiable {
  let trackId: UInt64
  let classLabel: String
  let classConfidence: Float
  let yawInBikeDegrees: Float
  let pitchInBikeDegrees: Float
  let estimatedDistanceMeters: Float
  let angularVelocityDegPerSec: Float
  let radialVelocityMetersPerSec: Float
  let ageFrames: Int
  let isReliable: Bool

  var id: UInt64 { trackId }
}

extension TrackSession {
  static func load(from url: URL) throws -> TrackSession {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(TrackSession.self, from: data)
  }

  static func loadFromBundle(named name: String = "track") throws -> TrackSession {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
      throw NSError(
        domain: "Bike360", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "\(name).json not found in app bundle"]
      )
    }
    return try load(from: url)
  }
}
