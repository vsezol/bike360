import CoreMedia
import Foundation

// Stream of orientation samples from the bike's frame (MPU-6050 over BLE
// in production, mock for now). The bike-frame orientation is what we
// subtract from helmet orientation to know where the rider is looking
// relative to the bike, and from world-coords to project objects into
// the bike's frame for the 3D map.
public protocol BikeOrientationSource: Sendable {
  func orientations() -> AsyncStream<Orientation>
}

// Same shape, but for the helmet (camera). On Insta360 the gyro/accel
// stream lives inside the .insv metadata atoms; the mock source returns
// a constant zero orientation.
public protocol HelmetOrientationSource: Sendable {
  func orientations() -> AsyncStream<Orientation>
}

// Constant-zero implementations for testing the rest of the pipeline
// without real sensors. Yaw=0/pitch=0/roll=0 means the rider sits straight
// on a bike that's heading forward with no lean.
public final class MockBikeOrientationSource: BikeOrientationSource {
  public init() {}
  public func orientations() -> AsyncStream<Orientation> {
    AsyncStream { continuation in
      continuation.yield(.zero())
      continuation.finish()
    }
  }
}

public final class MockHelmetOrientationSource: HelmetOrientationSource {
  public init() {}
  public func orientations() -> AsyncStream<Orientation> {
    AsyncStream { continuation in
      continuation.yield(.zero())
      continuation.finish()
    }
  }
}
