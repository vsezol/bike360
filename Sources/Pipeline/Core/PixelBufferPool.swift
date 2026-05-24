import CoreVideo
import Foundation

// Wraps CVPixelBufferPool so modules don't allocate a fresh buffer per frame.
// Pools are keyed by (width, height) so a single module can serve front/back
// with different sizes if needed. Thread-safe via an internal lock.
public final class PixelBufferPool: @unchecked Sendable {
  private struct Key: Hashable {
    let width: Int
    let height: Int
  }

  private let lock = NSLock()
  private var pools: [Key: CVPixelBufferPool] = [:]

  public init() {}

  public func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    let pool = try cachedPool(width: width, height: height)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    guard status == kCVReturnSuccess, let buffer else {
      throw PixelBufferPoolError.allocationFailed(status: status)
    }
    return buffer
  }

  private func cachedPool(width: Int, height: Int) throws -> CVPixelBufferPool {
    let key = Key(width: width, height: height)
    lock.lock()
    defer { lock.unlock() }
    if let pool = pools[key] {
      return pool
    }
    let pool = try Self.makePool(width: width, height: height)
    pools[key] = pool
    return pool
  }

  private static func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
    let bufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      nil,
      bufferAttributes as CFDictionary,
      &pool
    )
    guard status == kCVReturnSuccess, let pool else {
      throw PixelBufferPoolError.poolCreationFailed(status: status)
    }
    return pool
  }
}

public enum PixelBufferPoolError: Error, CustomStringConvertible {
  case poolCreationFailed(status: CVReturn)
  case allocationFailed(status: CVReturn)

  public var description: String {
    switch self {
    case .poolCreationFailed(let status):
      return "CVPixelBufferPoolCreate failed with status \(status)"
    case .allocationFailed(let status):
      return "CVPixelBufferPoolCreatePixelBuffer failed with status \(status)"
    }
  }
}
