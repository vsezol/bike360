import CoreMedia
import CoreVideo

// CVPixelBuffer is reference-counted but treated as immutable while in flight
// through the pipeline. Sendable conformance is unchecked.
public struct Frame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let timestamp: CMTime
  public let lens: Lens
  public let intrinsics: CameraIntrinsics

  public init(
    pixelBuffer: CVPixelBuffer,
    timestamp: CMTime,
    lens: Lens,
    intrinsics: CameraIntrinsics
  ) {
    self.pixelBuffer = pixelBuffer
    self.timestamp = timestamp
    self.lens = lens
    self.intrinsics = intrinsics
  }

  public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
  public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
  public var pixelFormat: OSType { CVPixelBufferGetPixelFormatType(pixelBuffer) }
}
