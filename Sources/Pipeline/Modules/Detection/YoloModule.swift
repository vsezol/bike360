import CoreML
import CoreVideo
import Foundation
import Vision

// Object detection on one rectilinear tile via Vision + CoreML.
//
// One YoloModule instance wraps a loaded MLModel. The same MLModel can be
// shared across multiple YoloModule instances (one per tile) for parallel
// inference — Vision and the underlying MLModel are thread-safe.
//
// Output: [Detection] in tile-local coordinates already lifted to lens
// angles (yaw + pitch) and metric distance via the pinhole height formula.
// Classes outside DetectionClass (sofa, banana, …) are filtered out.
public final class YoloModule: PipelineModule, @unchecked Sendable {
  public typealias Input = Tile
  public typealias Output = [Detection]

  public struct Settings: Sendable {
    public var confidenceThreshold: Float

    public init(confidenceThreshold: Float = 0.25) {
      self.confidenceThreshold = confidenceThreshold
    }

    public static let `default` = Settings()
  }

  private let visionModel: VNCoreMLModel
  private let settings: Settings

  public init(mlModel: MLModel, settings: Settings = .default) throws {
    do {
      self.visionModel = try VNCoreMLModel(for: mlModel)
    } catch {
      throw YoloError.modelLoadFailed(underlying: error)
    }
    self.settings = settings
  }

  public convenience init(modelURL: URL, settings: Settings = .default) throws {
    let compiledURL = try Self.resolveCompiledModelURL(from: modelURL)
    let config = MLModelConfiguration()
    config.computeUnits = .all  // ANE + GPU + CPU, auto-routed by Core ML.
    let mlModel: MLModel
    do {
      mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
    } catch {
      throw YoloError.modelLoadFailed(underlying: error)
    }
    try self.init(mlModel: mlModel, settings: settings)
  }

  // Xcode normally compiles .mlpackage / .mlmodel into the runtime-loadable
  // .mlmodelc bundle for us. Without Xcode (SwiftPM-only), we do it ourselves
  // via MLModel.compileModel(at:), then cache the result next to the source
  // so we don't pay the compile cost on every CLI invocation.
  private static func resolveCompiledModelURL(from sourceURL: URL) throws -> URL {
    let ext = sourceURL.pathExtension.lowercased()
    if ext == "mlmodelc" {
      return sourceURL
    }

    let cachedURL = sourceURL
      .deletingPathExtension()
      .appendingPathExtension("mlmodelc")
    if FileManager.default.fileExists(atPath: cachedURL.path) {
      return cachedURL
    }

    do {
      let tempCompiledURL = try MLModel.compileModel(at: sourceURL)
      try FileManager.default.moveItem(at: tempCompiledURL, to: cachedURL)
      return cachedURL
    } catch {
      throw YoloError.modelLoadFailed(underlying: error)
    }
  }

  public func process(_ tile: Tile) async throws -> [Detection] {
    let request = VNCoreMLRequest(model: visionModel)
    request.imageCropAndScaleOption = .scaleFill

    do {
      let handler = VNImageRequestHandler(cvPixelBuffer: tile.frame.pixelBuffer, options: [:])
      try handler.perform([request])
    } catch {
      throw YoloError.inferenceFailed(underlying: error)
    }

    guard let observations = request.results as? [VNRecognizedObjectObservation] else {
      return []
    }

    return observations.compactMap { observation in
      makeDetection(from: observation, tile: tile)
    }
  }

  private func makeDetection(
    from observation: VNRecognizedObjectObservation,
    tile: Tile
  ) -> Detection? {
    guard let topLabel = observation.labels.first,
          topLabel.confidence >= settings.confidenceThreshold,
          let detectionClass = DetectionClass(yoloLabel: topLabel.identifier)
    else { return nil }

    // Vision returns bbox in normalized coords with origin bottom-left
    // (graphics convention). We flip Y so detections speak the same
    // top-left origin language as everything else in our pipeline.
    let visionBbox = observation.boundingBox
    let bbox = CGRect(
      x: visionBbox.minX,
      y: 1.0 - visionBbox.maxY,
      width: visionBbox.width,
      height: visionBbox.height
    )

    let tileFrame = tile.frame
    let bboxCxPx = Float(bbox.midX) * Float(tileFrame.width)
    let bboxCyPx = Float(bbox.midY) * Float(tileFrame.height)

    let dx = (bboxCxPx - tileFrame.intrinsics.principalPointX) / tileFrame.intrinsics.focalLengthX
    let dy = (bboxCyPx - tileFrame.intrinsics.principalPointY) / tileFrame.intrinsics.focalLengthY

    let yawOffsetDeg = atan(dx) * 180.0 / .pi
    let pitchOffsetDeg = -atan(dy) * 180.0 / .pi  // image +Y is down, world pitch +Y is up

    let yawInLens = tile.yawDegrees + yawOffsetDeg
    let pitchInLens = tile.pitchDegrees + pitchOffsetDeg

    // Distance via pinhole height formula.
    let bboxHeightPx = Float(bbox.height) * Float(tileFrame.height)
    guard bboxHeightPx > 0 else { return nil }
    let distance = (detectionClass.realWorldHeightMeters * tileFrame.intrinsics.focalLengthY) / bboxHeightPx

    return Detection(
      objectClass: detectionClass,
      confidence: topLabel.confidence,
      bbox: bbox,
      yawInLensDegrees: yawInLens,
      pitchInLensDegrees: pitchInLens,
      estimatedDistanceMeters: distance,
      lens: tile.lens,
      sourceTileYawDegrees: tile.yawDegrees,
      sourceTilePitchDegrees: tile.pitchDegrees
    )
  }
}

public enum YoloError: Error, CustomStringConvertible {
  case modelLoadFailed(underlying: any Error)
  case inferenceFailed(underlying: any Error)

  public var description: String {
    switch self {
    case .modelLoadFailed(let err): return "Failed to load YOLO model: \(err)"
    case .inferenceFailed(let err): return "YOLO inference failed: \(err)"
    }
  }
}
