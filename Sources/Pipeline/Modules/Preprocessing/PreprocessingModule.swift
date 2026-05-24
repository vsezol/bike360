import CoreImage
import CoreVideo
import Foundation
import Metal

// Light per-frame conditioning before geometric correction:
// exposure normalization + a touch of noise reduction. Front and back
// frames are filtered in parallel since they share no GPU state.
public final class PreprocessingModule: PipelineModule, @unchecked Sendable {
  public typealias Input = StereoFrame
  public typealias Output = StereoFrame

  public struct Settings: Sendable {
    public var exposureEV: Float
    public var noiseLevel: Float
    public var sharpness: Float

    public init(exposureEV: Float = 0.0, noiseLevel: Float = 0.02, sharpness: Float = 0.4) {
      self.exposureEV = exposureEV
      self.noiseLevel = noiseLevel
      self.sharpness = sharpness
    }

    public static let `default` = Settings()
  }

  private let context: CIContext
  private let settings: Settings
  private let bufferPool: PixelBufferPool

  public init(settings: Settings = .default, metalDevice: MTLDevice? = nil) {
    let device = metalDevice ?? MTLCreateSystemDefaultDevice()
    self.context = device.map { CIContext(mtlDevice: $0) } ?? CIContext()
    self.settings = settings
    self.bufferPool = PixelBufferPool()
  }

  public func process(_ input: StereoFrame) async throws -> StereoFrame {
    async let frontProcessed = filter(input.front)
    async let backProcessed = filter(input.back)
    return try await StereoFrame(
      front: frontProcessed,
      back: backProcessed,
      sequenceNumber: input.sequenceNumber
    )
  }

  private func filter(_ frame: Frame) throws -> Frame {
    let inputImage = CIImage(cvPixelBuffer: frame.pixelBuffer)

    let exposed = inputImage.applyingFilter(
      "CIExposureAdjust",
      parameters: [kCIInputEVKey: settings.exposureEV]
    )
    let denoised = exposed.applyingFilter(
      "CINoiseReduction",
      parameters: [
        "inputNoiseLevel": settings.noiseLevel,
        "inputSharpness": settings.sharpness,
      ]
    )

    let outputBuffer = try bufferPool.pixelBuffer(
      width: frame.width,
      height: frame.height
    )
    context.render(denoised, to: outputBuffer)

    return Frame(
      pixelBuffer: outputBuffer,
      timestamp: frame.timestamp,
      lens: frame.lens,
      intrinsics: frame.intrinsics
    )
  }
}

public enum PreprocessingError: Error, CustomStringConvertible {
  case failedToCreatePixelBuffer(status: CVReturn)

  public var description: String {
    switch self {
    case .failedToCreatePixelBuffer(let status):
      return "CVPixelBufferCreate failed with status \(status)"
    }
  }
}
