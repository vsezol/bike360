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
    public var detectionConfig: DetectionConfig
    // IoU above which two boxes (any classes) are treated as the same object
    // by the class-agnostic NMS pass; the lower-confidence one is dropped.
    public var nmsIoUThreshold: Float
    // Pluggable distance estimation (ground-plane / pinhole / …), configured
    // via distance-config.json. See DistanceStrategy.
    public var distanceEstimator: DistanceEstimator

    public init(
      confidenceThreshold: Float = 0.25,
      detectionConfig: DetectionConfig,
      nmsIoUThreshold: Float = 0.55,
      distanceEstimator: DistanceEstimator = .default
    ) {
      self.confidenceThreshold = confidenceThreshold
      self.detectionConfig = detectionConfig
      self.nmsIoUThreshold = nmsIoUThreshold
      self.distanceEstimator = distanceEstimator
    }
  }

  private let visionModel: VNCoreMLModel
  private let settings: Settings

  // Expose the active detection config so callers (CLI overlay drawer)
  // can use the same color/height table that drove the classification.
  public var config: DetectionConfig { settings.detectionConfig }

  public init(mlModel: MLModel, settings: Settings) throws {
    do {
      self.visionModel = try VNCoreMLModel(for: mlModel)
    } catch {
      throw YoloError.modelLoadFailed(underlying: error)
    }
    self.settings = settings
  }

  public convenience init(modelURL: URL, settings: Settings) throws {
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

    let detections = observations.compactMap { observation in
      makeDetection(from: observation, tile: tile)
    }
    // Vision runs NMS per class, so the same object can survive as two
    // overlapping boxes of different classes (e.g. a van read as both "truck"
    // and "car"). They then get different pinhole distances (height depends on
    // class) and split into two tracks. A class-agnostic NMS pass collapses
    // such overlaps to the single most-confident box.
    return Self.classAgnosticNMS(detections, iouThreshold: settings.nmsIoUThreshold)
  }

  // Greedy non-max suppression across ALL classes: keep boxes in descending
  // confidence, drop any that overlaps an already-kept box beyond the IoU
  // threshold regardless of its class.
  static func classAgnosticNMS(_ detections: [Detection], iouThreshold: Float) -> [Detection] {
    let ordered = detections.sorted { $0.confidence > $1.confidence }
    var kept: [Detection] = []
    for detection in ordered {
      let overlaps = kept.contains { intersectionOverUnion($0.bbox, detection.bbox) > iouThreshold }
      if !overlaps { kept.append(detection) }
    }
    return kept
  }

  static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Float {
    let intersection = a.intersection(b)
    guard !intersection.isNull else { return 0 }
    let interArea = Float(intersection.width * intersection.height)
    let union = Float(a.width * a.height + b.width * b.height) - interArea
    return union > 0 ? interArea / union : 0
  }

  private func makeDetection(
    from observation: VNRecognizedObjectObservation,
    tile: Tile
  ) -> Detection? {
    guard let topLabel = observation.labels.first,
          topLabel.confidence >= settings.confidenceThreshold
    else { return nil }

    let camelKey = Self.toCamelCase(topLabel.identifier)
    guard let classInfo = settings.detectionConfig.info(for: camelKey) else { return nil }

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

    // Distance via the configured strategies (ground-plane / pinhole / …),
    // each responsible for its own range band. See DistanceStrategy and
    // distance-config.json — no method-specific branching lives here anymore.
    guard let distance = settings.distanceEstimator.estimate(
      bbox: bbox,
      intrinsics: tileFrame.intrinsics,
      tilePitchDegrees: tile.pitchDegrees,
      classHeightMeters: classInfo.heightMeters
    ) else { return nil }

    // Sanity range: discard implausible distances.
    guard distance >= 0.5, distance <= 80 else { return nil }

    // Reject the rig itself. Two consistent false-positive sources on a
    // helmet-mounted 360 cam, confirmed in the data:
    //  1. The rear lens sees the rider's/passenger's own body ~1–1.5 m back
    //     as a stable "person" — anything within 2.5 m is the rig, not road.
    //  2. Handlebars, mirrors and the road right under the nose sit in the
    //     lower fisheye zone and read as steeply-downward (pitch < −28°)
    //     bicycle/motorcycle detections.
    // NOTE: 2.5 m threshold is tuned for the current helmet mount; revisit
    // if the camera moves.
    if distance < 2.5 { return nil }
    if pitchInLens < -28 { return nil }

    return Detection(
      classLabel: camelKey,
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

extension YoloModule {
  // "traffic light" -> "trafficLight". COCO labels are lowercased words
  // separated by spaces, so split on space, capitalize tail words, join.
  static func toCamelCase(_ rawLabel: String) -> String {
    let parts = rawLabel.lowercased().split(separator: " ", omittingEmptySubsequences: true)
    guard let head = parts.first else { return "" }
    let tail = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
    return ([String(head)] + tail).joined()
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
