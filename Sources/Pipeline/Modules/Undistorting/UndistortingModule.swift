import CoreVideo
import Foundation
import Metal

// Geometric correction. Supports two projection modes:
//
//  - .rectilinear(tiles): K virtual pinhole cameras panned around the lens
//    axis. Each tile is a clean rectilinear image (best for off-the-shelf
//    YOLO), but every tile loses anything beyond its FOV and the union of
//    tiles can leave triangular black corners where rectilinear extends
//    past the fisheye coverage.
//
//  - .equirectangular: a single spherical projection per lens. Every pixel
//    of the input fisheye is preserved (no FOV clipping, no black corners,
//    no rectilinear stretch in the center). Distortion grows toward the
//    lens edges instead of being concentrated in the corners — important
//    for our safety use case where missing an object is unacceptable.
public final class UndistortingModule: PipelineModule, @unchecked Sendable {
  public typealias Input = StereoFrame
  public typealias Output = TiledFrame

  public struct TileConfiguration: Sendable, Hashable {
    public var yawDegrees: Float
    public var pitchDegrees: Float
    // Horizontal FOV. Vertical FOV is derived from outputWidth:outputHeight
    // ratio assuming square pixels (focal computed from horizontal FOV).
    public var horizontalFieldOfViewDegrees: Float
    public var outputWidth: Int
    public var outputHeight: Int

    public init(
      yawDegrees: Float,
      pitchDegrees: Float = 0,
      horizontalFieldOfViewDegrees: Float,
      outputWidth: Int,
      outputHeight: Int
    ) {
      self.yawDegrees = yawDegrees
      self.pitchDegrees = pitchDegrees
      self.horizontalFieldOfViewDegrees = horizontalFieldOfViewDegrees
      self.outputWidth = outputWidth
      self.outputHeight = outputHeight
    }

    // Square convenience init — keeps fov label legacy-friendly.
    public init(
      yawDegrees: Float,
      pitchDegrees: Float = 0,
      fieldOfViewDegrees: Float,
      outputSize: Int
    ) {
      self.init(
        yawDegrees: yawDegrees,
        pitchDegrees: pitchDegrees,
        horizontalFieldOfViewDegrees: fieldOfViewDegrees,
        outputWidth: outputSize,
        outputHeight: outputSize
      )
    }

    public var verticalFieldOfViewDegrees: Float {
      let focal = Float(outputWidth) / 2.0 / tan(horizontalFieldOfViewDegrees * .pi / 360.0)
      return atan(Float(outputHeight) / 2.0 / focal) * 360.0 / .pi
    }
  }

  public struct EquirectConfiguration: Sendable, Hashable {
    public var outputWidth: Int
    public var outputHeight: Int
    public var horizontalFieldOfViewDegrees: Float
    public var verticalFieldOfViewDegrees: Float

    public init(
      outputWidth: Int,
      outputHeight: Int,
      horizontalFieldOfViewDegrees: Float,
      verticalFieldOfViewDegrees: Float
    ) {
      self.outputWidth = outputWidth
      self.outputHeight = outputHeight
      self.horizontalFieldOfViewDegrees = horizontalFieldOfViewDegrees
      self.verticalFieldOfViewDegrees = verticalFieldOfViewDegrees
    }
  }

  public struct StereographicConfiguration: Sendable, Hashable {
    public var outputSize: Int
    public var fieldOfViewDegrees: Float

    public init(outputSize: Int, fieldOfViewDegrees: Float) {
      self.outputSize = outputSize
      self.fieldOfViewDegrees = fieldOfViewDegrees
    }
  }

  public enum Projection: Sendable {
    case rectilinear(tiles: [TileConfiguration])
    case equirectangular(EquirectConfiguration)
    case stereographic(StereographicConfiguration)
  }

  public struct Settings: Sendable {
    public var projection: Projection

    public init(projection: Projection) {
      self.projection = projection
    }

    // 3 rectilinear tiles per lens, FOV 90° square — natural proportions
    // with minimal edge stretching. yaw -60/0/+60 gives 30° overlap zones
    // for NMS. Vertical coverage = 90° — buildings clip at ~50° above
    // horizon, but everything on the road (cars, people, signs) stays in
    // frame undistorted. This is the right trade-off for safety detection.
    public static let threeTilesPerLens = Settings(projection: .rectilinear(tiles: [
      TileConfiguration(yawDegrees: -60, fieldOfViewDegrees: 90, outputSize: 1024),
      TileConfiguration(yawDegrees: 0, fieldOfViewDegrees: 90, outputSize: 1024),
      TileConfiguration(yawDegrees: 60, fieldOfViewDegrees: 90, outputSize: 1024),
    ]))

    // Wider 130° FOV version — for cases where vertical coverage matters
    // more than edge naturalness (e.g. urban scenes with tall signage).
    public static let threeWideTilesPerLens = Settings(projection: .rectilinear(tiles: [
      TileConfiguration(yawDegrees: -90, fieldOfViewDegrees: 130, outputSize: 1024),
      TileConfiguration(yawDegrees: 0, fieldOfViewDegrees: 130, outputSize: 1024),
      TileConfiguration(yawDegrees: 90, fieldOfViewDegrees: 130, outputSize: 1024),
    ]))

    // 3×3 grid of clean rectilinear tiles per lens — 3 yaw × 3 pitch.
    // FOV 90° per tile + yaw spacing 60° (30° overlap) + pitch spacing 50°
    // gives a horizontal coverage of 210° and vertical coverage of 190°,
    // matching or exceeding the lens hemisphere. Every tile is a normal
    // flat picture (no fisheye look), nothing is lost. 9 tiles per lens
    // × 2 lenses = 18 YOLO inputs per stereo frame.
    public static let nineTilesGridPerLens: Settings = {
      let yaws: [Float] = [-60, 0, 60]
      let pitches: [Float] = [-50, 0, 50]
      let tiles = pitches.flatMap { pitch in
        yaws.map { yaw in
          TileConfiguration(
            yawDegrees: yaw,
            pitchDegrees: pitch,
            fieldOfViewDegrees: 90,
            outputSize: 1024
          )
        }
      }
      return Settings(projection: .rectilinear(tiles: tiles))
    }()

    public static let twoTilesPerLens = Settings(projection: .rectilinear(tiles: [
      TileConfiguration(yawDegrees: -50, fieldOfViewDegrees: 140, outputSize: 1280),
      TileConfiguration(yawDegrees: 50, fieldOfViewDegrees: 140, outputSize: 1280),
    ]))

    public static let singleCenterTile = Settings(projection: .rectilinear(tiles: [
      TileConfiguration(yawDegrees: 0, fieldOfViewDegrees: 120, outputSize: 1920),
    ]))

    // Equirectangular covering the full 190° hemisphere of one fisheye lens.
    // Square 1024×1024 ≈ 5.4 pixels per degree, comfortable for visualization
    // and downstream ML alike. No data is lost.
    public static let equirectangularFullHemisphere = Settings(projection: .equirectangular(
      EquirectConfiguration(
        outputWidth: 1024,
        outputHeight: 1024,
        horizontalFieldOfViewDegrees: 190,
        verticalFieldOfViewDegrees: 190
      )
    ))

    // Stereographic covering the full 190° hemisphere with a tiny margin.
    // Conformal: object shapes stay recognisable. Default projection because
    // it's the best trade-off for our use case — full coverage + minimal
    // shape distortion.
    public static let stereographicFullHemisphere = Settings(projection: .stereographic(
      StereographicConfiguration(outputSize: 1024, fieldOfViewDegrees: 195)
    ))

    public static let `default` = threeTilesPerLens
  }

  private struct RectilinearParams {
    var inputFocal: Float
    var inputCx: Float
    var inputCy: Float
    var inputWidth: Float
    var inputHeight: Float
    var inputMaxThetaRadians: Float
    var outputFocal: Float
    var outputWidth: Float
    var outputHeight: Float
    var tileYawRadians: Float
    var tilePitchRadians: Float
  }

  private struct EquirectParams {
    var inputFocal: Float
    var inputCx: Float
    var inputCy: Float
    var inputWidth: Float
    var inputHeight: Float
    var inputMaxThetaRadians: Float
    var outputWidth: Float
    var outputHeight: Float
    var outputFovHorizontalRadians: Float
    var outputFovVerticalRadians: Float
  }

  private struct StereographicParams {
    var inputFocal: Float
    var inputCx: Float
    var inputCy: Float
    var inputWidth: Float
    var inputHeight: Float
    var inputMaxThetaRadians: Float
    var outputFocal: Float
    var outputWidth: Float
    var outputHeight: Float
  }

  private let context: MetalContext
  private let rectilinearPipeline: MTLComputePipelineState
  private let equirectPipeline: MTLComputePipelineState
  private let stereographicPipeline: MTLComputePipelineState
  private let textureCache: CVMetalTextureCache
  private let bufferPool: PixelBufferPool
  private let settings: Settings

  public init(context: MetalContext, settings: Settings = .default) throws {
    self.context = context
    self.rectilinearPipeline = try context.makeComputePipelineState(
      functionName: "undistortFisheyeEquidistant"
    )
    self.equirectPipeline = try context.makeComputePipelineState(
      functionName: "equirectangularFromFisheye"
    )
    self.stereographicPipeline = try context.makeComputePipelineState(
      functionName: "stereographicFromFisheye"
    )
    self.settings = settings
    self.bufferPool = PixelBufferPool()

    var cache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(
      kCFAllocatorDefault, nil, context.device, nil, &cache
    )
    guard status == kCVReturnSuccess, let cache else {
      throw UndistortingError.textureCacheCreationFailed(status: status)
    }
    self.textureCache = cache
  }

  public func process(_ input: StereoFrame) async throws -> TiledFrame {
    async let frontTiles = renderTiles(for: input.front)
    async let backTiles = renderTiles(for: input.back)
    let tiles = try await frontTiles + backTiles
    return TiledFrame(
      tiles: tiles,
      sequenceNumber: input.sequenceNumber,
      captureTimestamp: input.captureTimestamp
    )
  }

  private func renderTiles(for frame: Frame) throws -> [Tile] {
    switch settings.projection {
    case .rectilinear(let configs):
      return try configs.map { try renderRectilinear(frame: frame, config: $0) }
    case .equirectangular(let config):
      return [try renderEquirect(frame: frame, config: config)]
    case .stereographic(let config):
      return [try renderStereographic(frame: frame, config: config)]
    }
  }

  private func renderRectilinear(frame: Frame, config: TileConfiguration) throws -> Tile {
    let outputWidth = config.outputWidth
    let outputHeight = config.outputHeight
    let outputBuffer = try bufferPool.pixelBuffer(width: outputWidth, height: outputHeight)
    let inputTexture = try makeTexture(from: frame.pixelBuffer, readOnly: true)
    let outputTexture = try makeTexture(from: outputBuffer, readOnly: false)

    let horizontalFovRadians = config.horizontalFieldOfViewDegrees * .pi / 180.0
    let outputFocal = Float(outputWidth) / 2.0 / tan(horizontalFovRadians / 2.0)
    let inputMaxTheta = (frame.intrinsics.fieldOfViewDegrees / 2.0) * .pi / 180.0
    let yawRadians = config.yawDegrees * .pi / 180.0
    let pitchRadians = config.pitchDegrees * .pi / 180.0

    var params = RectilinearParams(
      inputFocal: frame.intrinsics.focalLengthX,
      inputCx: frame.intrinsics.principalPointX,
      inputCy: frame.intrinsics.principalPointY,
      inputWidth: Float(frame.intrinsics.imageWidth),
      inputHeight: Float(frame.intrinsics.imageHeight),
      inputMaxThetaRadians: inputMaxTheta,
      outputFocal: outputFocal,
      outputWidth: Float(outputWidth),
      outputHeight: Float(outputHeight),
      tileYawRadians: yawRadians,
      tilePitchRadians: pitchRadians
    )

    try dispatch(
      pipeline: rectilinearPipeline,
      inputTexture: inputTexture,
      outputTexture: outputTexture,
      width: outputWidth,
      height: outputHeight,
      params: &params,
      paramsSize: MemoryLayout<RectilinearParams>.stride
    )

    let intrinsics = CameraIntrinsics(
      focalLengthX: outputFocal,
      focalLengthY: outputFocal,
      principalPointX: Float(outputWidth) / 2.0,
      principalPointY: Float(outputHeight) / 2.0,
      fieldOfViewDegrees: config.horizontalFieldOfViewDegrees,
      imageWidth: outputWidth,
      imageHeight: outputHeight
    )
    let outputFrame = Frame(
      pixelBuffer: outputBuffer,
      timestamp: frame.timestamp,
      lens: frame.lens,
      intrinsics: intrinsics
    )
    return Tile(
      frame: outputFrame,
      lens: frame.lens,
      yawDegrees: config.yawDegrees,
      pitchDegrees: config.pitchDegrees
    )
  }

  private func renderEquirect(frame: Frame, config: EquirectConfiguration) throws -> Tile {
    let outputBuffer = try bufferPool.pixelBuffer(
      width: config.outputWidth, height: config.outputHeight
    )
    let inputTexture = try makeTexture(from: frame.pixelBuffer, readOnly: true)
    let outputTexture = try makeTexture(from: outputBuffer, readOnly: false)

    let inputMaxTheta = (frame.intrinsics.fieldOfViewDegrees / 2.0) * .pi / 180.0
    let hFovRadians = config.horizontalFieldOfViewDegrees * .pi / 180.0
    let vFovRadians = config.verticalFieldOfViewDegrees * .pi / 180.0

    var params = EquirectParams(
      inputFocal: frame.intrinsics.focalLengthX,
      inputCx: frame.intrinsics.principalPointX,
      inputCy: frame.intrinsics.principalPointY,
      inputWidth: Float(frame.intrinsics.imageWidth),
      inputHeight: Float(frame.intrinsics.imageHeight),
      inputMaxThetaRadians: inputMaxTheta,
      outputWidth: Float(config.outputWidth),
      outputHeight: Float(config.outputHeight),
      outputFovHorizontalRadians: hFovRadians,
      outputFovVerticalRadians: vFovRadians
    )

    try dispatch(
      pipeline: equirectPipeline,
      inputTexture: inputTexture,
      outputTexture: outputTexture,
      width: config.outputWidth,
      height: config.outputHeight,
      params: &params,
      paramsSize: MemoryLayout<EquirectParams>.stride
    )

    // For equirect the camera model is spherical, not pinhole. We reuse
    // CameraIntrinsics as a carrier of size + FOV, but focalLength/principal
    // point are not meaningful here — downstream consumers should check
    // Tile.projectionIsEquirect (TODO) instead of treating these as pinhole.
    let intrinsics = CameraIntrinsics(
      focalLengthX: 0,
      focalLengthY: 0,
      principalPointX: Float(config.outputWidth) / 2.0,
      principalPointY: Float(config.outputHeight) / 2.0,
      fieldOfViewDegrees: max(
        config.horizontalFieldOfViewDegrees, config.verticalFieldOfViewDegrees
      ),
      imageWidth: config.outputWidth,
      imageHeight: config.outputHeight
    )
    let outputFrame = Frame(
      pixelBuffer: outputBuffer,
      timestamp: frame.timestamp,
      lens: frame.lens,
      intrinsics: intrinsics
    )
    return Tile(frame: outputFrame, lens: frame.lens, yawDegrees: 0)
  }

  private func renderStereographic(frame: Frame, config: StereographicConfiguration) throws -> Tile {
    let outputSize = config.outputSize
    let outputBuffer = try bufferPool.pixelBuffer(width: outputSize, height: outputSize)
    let inputTexture = try makeTexture(from: frame.pixelBuffer, readOnly: true)
    let outputTexture = try makeTexture(from: outputBuffer, readOnly: false)

    let inputMaxTheta = (frame.intrinsics.fieldOfViewDegrees / 2.0) * .pi / 180.0
    let fovRadians = config.fieldOfViewDegrees * .pi / 180.0
    // r_max on the stereographic plane = 2*tan(theta_max/2), where theta_max = fov/2.
    // We want this r_max to fill the output radius (outputSize/2 pixels).
    let rMax = 2.0 * tan(fovRadians / 4.0)
    let outputFocal = Float(outputSize) / 2.0 / rMax

    var params = StereographicParams(
      inputFocal: frame.intrinsics.focalLengthX,
      inputCx: frame.intrinsics.principalPointX,
      inputCy: frame.intrinsics.principalPointY,
      inputWidth: Float(frame.intrinsics.imageWidth),
      inputHeight: Float(frame.intrinsics.imageHeight),
      inputMaxThetaRadians: inputMaxTheta,
      outputFocal: outputFocal,
      outputWidth: Float(outputSize),
      outputHeight: Float(outputSize)
    )

    try dispatch(
      pipeline: stereographicPipeline,
      inputTexture: inputTexture,
      outputTexture: outputTexture,
      width: outputSize,
      height: outputSize,
      params: &params,
      paramsSize: MemoryLayout<StereographicParams>.stride
    )

    // Carry size + FOV; focal/principal aren't a pinhole model here either.
    let intrinsics = CameraIntrinsics(
      focalLengthX: outputFocal,
      focalLengthY: outputFocal,
      principalPointX: Float(outputSize) / 2.0,
      principalPointY: Float(outputSize) / 2.0,
      fieldOfViewDegrees: config.fieldOfViewDegrees,
      imageWidth: outputSize,
      imageHeight: outputSize
    )
    let outputFrame = Frame(
      pixelBuffer: outputBuffer,
      timestamp: frame.timestamp,
      lens: frame.lens,
      intrinsics: intrinsics
    )
    return Tile(frame: outputFrame, lens: frame.lens, yawDegrees: 0)
  }

  private func dispatch<P>(
    pipeline: MTLComputePipelineState,
    inputTexture: MTLTexture,
    outputTexture: MTLTexture,
    width: Int,
    height: Int,
    params: inout P,
    paramsSize: Int
  ) throws {
    guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
      throw UndistortingError.commandBufferCreationFailed
    }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw UndistortingError.encoderCreationFailed
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(inputTexture, index: 0)
    encoder.setTexture(outputTexture, index: 1)
    encoder.setBytes(&params, length: paramsSize, index: 0)

    let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
    let threadGroups = MTLSize(
      width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
      height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
      depth: 1
    )
    encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if let error = commandBuffer.error {
      throw UndistortingError.commandBufferFailed(underlying: error)
    }
  }

  private func makeTexture(from buffer: CVPixelBuffer, readOnly: Bool) throws -> MTLTexture {
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    var cvTexture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, buffer, nil,
      .bgra8Unorm, width, height, 0, &cvTexture
    )
    guard status == kCVReturnSuccess, let cvTexture,
          let texture = CVMetalTextureGetTexture(cvTexture)
    else {
      throw UndistortingError.textureCreationFailed(status: status, readOnly: readOnly)
    }
    return texture
  }
}

public enum UndistortingError: Error, CustomStringConvertible {
  case textureCacheCreationFailed(status: CVReturn)
  case textureCreationFailed(status: CVReturn, readOnly: Bool)
  case commandBufferCreationFailed
  case encoderCreationFailed
  case commandBufferFailed(underlying: any Error)

  public var description: String {
    switch self {
    case .textureCacheCreationFailed(let status):
      return "CVMetalTextureCacheCreate failed with status \(status)"
    case .textureCreationFailed(let status, let readOnly):
      return "CVMetalTextureCacheCreateTextureFromImage failed (readOnly=\(readOnly), status=\(status))"
    case .commandBufferCreationFailed: return "MTLCommandQueue.makeCommandBuffer() returned nil"
    case .encoderCreationFailed: return "MTLCommandBuffer.makeComputeCommandEncoder() returned nil"
    case .commandBufferFailed(let err): return "Metal command buffer failed: \(err)"
    }
  }
}
