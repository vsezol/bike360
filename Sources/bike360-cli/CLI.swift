import CoreGraphics
import CoreImage
import CoreMedia
import CoreML
import CoreText
import Foundation
import ImageIO
import Pipeline
import UniformTypeIdentifiers

@main
struct CLI {
  static func main() async {
    setbuf(stdout, nil)  // unbuffered stdout — critical for diagnosing crashes
    do {
      try await run()
    } catch {
      FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
      exit(1)
    }
    // Workaround: VNCoreMLModel / Vision deinit currently crashes on
    // macOS Command Line Tools after a successful inference. All work
    // (JSON, PNG, summary) is already flushed by this point, so we force
    // a clean exit instead of letting Swift run shutdown that segfaults.
    // This will go away once we move to a real Xcode-built iOS target.
    exit(0)
  }

  static func run() async throws {
    let parsed = try ArgParser.parse(CommandLine.arguments)
    switch parsed {
    case .help:
      printUsage()
    case .extract(let options):
      try await runExtract(options: options)
    case .batch(let options):
      try await runBatch(options: options)
    }
  }

  static func runBatch(options: BatchOptions) async throws {
    let videoURL = URL(fileURLWithPath: options.videoPath)
    let outputURL = URL(fileURLWithPath: options.outputDir)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    let source = InsvVideoSource(url: videoURL)
    let preprocessing = options.preprocess ? PreprocessingModule() : nil
    let metal = try MetalContext()
    let undistorting = try UndistortingModule(context: metal, settings: options.undistortSettings)

    let startIndex = UInt64(options.startFrame)
    let endIndex = startIndex + UInt64(options.count)
    var currentIndex: UInt64 = 0
    var processed = 0
    let started = Date()

    print("Batch: \(options.count) frames from \(options.startFrame) to \(options.startFrame + options.count - 1)")
    print("Output: \(outputURL.path)")
    print("Tiles per frame: \(options.undistortSettings.tileCount * 2) (\(options.undistortSettings.tileCount) per lens × 2 lenses)")
    print()

    for try await stereo in source.frames() {
      if currentIndex >= endIndex { break }
      if currentIndex < startIndex {
        currentIndex += 1
        continue
      }

      var current = stereo
      if let preprocessing {
        current = try await preprocessing.process(current)
      }
      let tiled = try await undistorting.process(current)
      try await writeBatchTiles(tiled.tiles, frameIndex: Int(currentIndex), to: outputURL)

      processed += 1
      if processed % 50 == 0 || processed == options.count {
        let elapsed = Date().timeIntervalSince(started)
        let fps = Double(processed) / elapsed
        let remaining = options.count - processed
        let eta = Double(remaining) / fps
        print(String(format: "  %d/%d frames | %.1f fps | ETA %ds", processed, options.count, fps, Int(eta)))
      }
      currentIndex += 1
    }

    let total = Date().timeIntervalSince(started)
    print()
    print(String(format: "Done. %d frames in %.1fs (%.1f fps avg, %d PNGs written)",
                 processed, total, Double(processed) / total, processed * (options.undistortSettings.tileCount * 2)))
  }

  static func writeBatchTiles(_ tiles: [Tile], frameIndex: Int, to dir: URL) async throws {
    let frameStr = String(format: "%06d", frameIndex)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for tile in tiles {
        let yawStr = signedTag("yaw", Int(tile.yawDegrees))
        let pitchStr = tile.pitchDegrees == 0 ? "" : "_" + signedTag("pitch", Int(tile.pitchDegrees))
        let lensStr = tile.lens.rawValue
        let url = dir.appendingPathComponent("\(frameStr)_\(lensStr)_\(yawStr)\(pitchStr).png")
        group.addTask {
          try PNGWriter.write(frame: tile.frame, to: url)
        }
      }
      try await group.waitForAll()
    }
  }

  static func runExtract(options: ExtractOptions) async throws {
    let videoURL = URL(fileURLWithPath: options.videoPath)
    let outputURL = URL(fileURLWithPath: options.outputDir)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    let source = InsvVideoSource(url: videoURL)
    let preprocessing = options.preprocess ? PreprocessingModule() : nil
    let undistorting: UndistortingModule?
    if options.undistort {
      let metal = try MetalContext()
      undistorting = try UndistortingModule(context: metal, settings: options.undistortSettings)
    } else {
      undistorting = nil
    }
    let yolo: YoloModule?
    if options.detect {
      print("Loading YOLO model from \(options.modelPath)...")
      yolo = try YoloModule(modelURL: URL(fileURLWithPath: options.modelPath))
      print("YOLO model loaded.")
    } else {
      yolo = nil
    }

    let started = Date()
    var currentIndex: UInt64 = 0
    let targetIndex = UInt64(options.frameIndex)

    for try await stereo in source.frames() {
      if currentIndex == targetIndex {
        try await processAndSave(
          stereo: stereo,
          options: options,
          outputDir: outputURL,
          preprocessing: preprocessing,
          undistorting: undistorting,
          yolo: yolo,
          startedAt: started
        )
        return
      }
      currentIndex += 1
    }
    throw CLIError.frameOutOfRange(requested: options.frameIndex, available: Int(currentIndex))
  }

  static func processAndSave(
    stereo: StereoFrame,
    options: ExtractOptions,
    outputDir: URL,
    preprocessing: PreprocessingModule?,
    undistorting: UndistortingModule?,
    yolo: YoloModule?,
    startedAt: Date
  ) async throws {
    let frame = options.frameIndex
    var stereoCurrent = stereo

    print("Frame \(frame) read in \(elapsed(since: startedAt))s")

    try writeStereo(stereoCurrent, frame: frame, stage: "raw", to: outputDir)

    if let preprocessing {
      let t0 = Date()
      stereoCurrent = try await preprocessing.process(stereoCurrent)
      print("  preprocessed in \(elapsed(since: t0))s")
      try writeStereo(stereoCurrent, frame: frame, stage: "preprocessed", to: outputDir)
    }

    guard let undistorting else {
      print("  done (no --undistort)")
      return
    }

    let t1 = Date()
    let tiled = try await undistorting.process(stereoCurrent)
    print("  undistorted into \(tiled.tiles.count) tiles in \(elapsed(since: t1))s")

    try writeTiles(tiled.tiles, frame: frame, to: outputDir)
    if options.mosaic {
      try writeMosaics(tiled.tiles, frame: frame, to: outputDir)
    }

    if let yolo {
      let t2 = Date()
      let detections = try await runYoloParallel(yolo: yolo, tiles: tiled.tiles)
      print("  detected \(detections.count) objects in \(elapsed(since: t2))s")
      try writeDetectionsJSON(detections, frame: frame, to: outputDir)
      try writeDetectionOverlays(tiles: tiled.tiles, detections: detections, frame: frame, to: outputDir)
      printDetectionsSummary(detections)
    }
  }

  static func writeDetectionOverlays(
    tiles: [Tile],
    detections: [Detection],
    frame: Int,
    to dir: URL
  ) throws {
    for tile in tiles {
      let tileDetections = detections.filter {
        $0.lens == tile.lens
          && $0.sourceTileYawDegrees == tile.yawDegrees
          && $0.sourceTilePitchDegrees == tile.pitchDegrees
      }
      if tileDetections.isEmpty { continue }

      let yawStr = signedTag("yaw", Int(tile.yawDegrees))
      let pitchStr = tile.pitchDegrees == 0 ? "" : "_" + signedTag("pitch", Int(tile.pitchDegrees))
      let url = dir.appendingPathComponent(
        "\(tile.lens.rawValue)_\(frame)_tile_\(yawStr)\(pitchStr)_detected.png"
      )
      try DetectionOverlayWriter.write(tile: tile, detections: tileDetections, to: url)
    }
    print("    overlay PNGs written")
  }

  static func runYoloParallel(yolo: YoloModule, tiles: [Tile]) async throws -> [Detection] {
    try await withThrowingTaskGroup(of: [Detection].self) { group in
      for tile in tiles {
        group.addTask {
          try await yolo.process(tile)
        }
      }
      var collected: [Detection] = []
      for try await batch in group {
        collected.append(contentsOf: batch)
      }
      return collected
    }
  }

  static func writeDetectionsJSON(_ detections: [Detection], frame: Int, to dir: URL) throws {
    let payload = DetectionsPayload(frame: frame, detections: detections.map(DetectionDTO.init))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    let url = dir.appendingPathComponent(String(format: "frame_%06d_detections.json", frame))
    try data.write(to: url)
    print("    detections JSON: \(url.lastPathComponent)")
  }

  static func printDetectionsSummary(_ detections: [Detection]) {
    let byClass = Dictionary(grouping: detections, by: { $0.objectClass })
    for (cls, items) in byClass.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      let closest = items.map { $0.estimatedDistanceMeters }.min() ?? 0
      let name = cls.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)
      print("    \(name) \(items.count)  closest \(String(format: "%.1f", closest))m")
    }
  }

  static func writeMosaics(_ tiles: [Tile], frame: Int, to dir: URL) throws {
    for lens in Lens.allCases {
      let lensTiles = tiles.filter { $0.lens == lens }
      guard lensTiles.count > 1 else { continue }
      let url = dir.appendingPathComponent("\(lens.rawValue)_\(frame)_mosaic.png")
      try MosaicWriter.write(tiles: lensTiles, to: url)
      print("    \(lens.rawValue) mosaic: \(url.lastPathComponent)")
    }
  }

  static func writeStereo(_ stereo: StereoFrame, frame: Int, stage: String, to dir: URL) throws {
    let frontURL = dir.appendingPathComponent("front_\(frame)_\(stage).png")
    let backURL = dir.appendingPathComponent("back_\(frame)_\(stage).png")
    try PNGWriter.write(frame: stereo.front, to: frontURL)
    try PNGWriter.write(frame: stereo.back, to: backURL)
    print("    \(stage): \(stereo.front.width)x\(stereo.front.height) (x2)")
  }

  static func writeTiles(_ tiles: [Tile], frame: Int, to dir: URL) throws {
    let tilesPerLens = Dictionary(grouping: tiles) { $0.lens }
    let isSingleTilePerLens = tilesPerLens.values.allSatisfy { $0.count == 1 }

    for tile in tiles {
      let lensStr = tile.lens.rawValue
      let suffix: String
      if isSingleTilePerLens {
        suffix = "projected"
      } else {
        let yawStr = signedTag("yaw", Int(tile.yawDegrees))
        let pitchStr = tile.pitchDegrees == 0 ? "" : "_" + signedTag("pitch", Int(tile.pitchDegrees))
        suffix = "tile_\(yawStr)\(pitchStr)"
      }
      let url = dir.appendingPathComponent("\(lensStr)_\(frame)_\(suffix).png")
      try PNGWriter.write(frame: tile.frame, to: url)
      print("    \(lensStr) \(suffix): \(tile.frame.width)x\(tile.frame.height)")
    }
  }

  static func signedTag(_ name: String, _ value: Int) -> String {
    if value == 0 { return "\(name)0" }
    return value > 0 ? "\(name)+\(value)" : "\(name)\(value)"
  }

  static func elapsed(since date: Date) -> String {
    String(format: "%.2f", Date().timeIntervalSince(date))
  }

  static func printUsage() {
    print(
      """
      bike360-cli — stage 1 pipeline runner

      Commands:
        extract <video> <frame_index> [options]

          Read a stereo frame from the .insv (renamed .mp4) file, run it
          through the requested pipeline stages, and save PNGs for visual
          inspection of every intermediate state.

          Options:
            --output-dir DIR    Directory for PNGs.            Default: ./out
            --preprocess        Apply PreprocessingModule.
            --undistort         Apply UndistortingModule.
            --tiles N           Number of rectilinear tiles per lens (1|2|3).
                                  1 = single centered tile (120° FOV, 1920px)
                                  2 = two tiles (±50° yaw, 110° FOV, 1280px)
                                  3 = three tiles (±60°/0° yaw, 90° FOV, 1024px)
                                Default: 3 (no edge loss, NMS overlap)

        batch <video> <start> <count> [options]

          Run the full pipeline on a range of frames, saving only the
          final tiles (no raw/preprocessed dumps) for batch inspection.
          Same projection / --tiles / --preprocess flags as extract.

          Files named: NNNNNN_<lens>_yaw±N[_pitch±N].png (zero-padded
          so they sort lexicographically).

      Examples:
        bike360-cli extract Resources/test_video_insv.mp4 100 --preprocess --undistort
        bike360-cli batch Resources/test_video_insv.mp4 13000 1000 --preprocess
      """
    )
  }
}

struct ExtractOptions {
  var videoPath: String
  var frameIndex: Int
  var outputDir: String = "./out"
  var preprocess: Bool = false
  var undistort: Bool = false
  var mosaic: Bool = false
  var detect: Bool = false
  var modelPath: String = "Resources/Models/yolo11n.mlpackage"
  var undistortSettings: UndistortingModule.Settings = .threeTilesPerLens
}

struct BatchOptions {
  var videoPath: String
  var startFrame: Int
  var count: Int
  var outputDir: String = "./out/batch"
  var preprocess: Bool = false
  var undistortSettings: UndistortingModule.Settings = .threeTilesPerLens
}

extension UndistortingModule.Settings {
  var tileCount: Int {
    switch projection {
    case .rectilinear(let tiles): return tiles.count
    case .equirectangular, .stereographic: return 1
    }
  }
}

enum CLIError: Error, CustomStringConvertible {
  case missingArgument(String)
  case unknownCommand(String)
  case invalidValue(name: String, value: String)
  case frameOutOfRange(requested: Int, available: Int)

  var description: String {
    switch self {
    case .missingArgument(let name): return "Missing argument: \(name)"
    case .unknownCommand(let name): return "Unknown command: \(name)"
    case .invalidValue(let name, let value): return "Invalid value for \(name): \(value)"
    case .frameOutOfRange(let requested, let available):
      return "Frame \(requested) is out of range — video has only \(available) frames"
    }
  }
}

enum ArgParser {
  enum ParseResult {
    case help
    case extract(ExtractOptions)
    case batch(BatchOptions)
  }

  static func parse(_ args: [String]) throws -> ParseResult {
    guard args.count >= 2 else { return .help }
    let command = args[1]
    switch command {
    case "-h", "--help", "help":
      return .help
    case "batch":
      return try parseBatch(args)
    case "extract":
      guard args.count >= 3 else { throw CLIError.missingArgument("video path") }
      guard args.count >= 4 else { throw CLIError.missingArgument("frame index") }
      guard let frameIndex = Int(args[3]) else {
        throw CLIError.invalidValue(name: "frame_index", value: args[3])
      }
      var options = ExtractOptions(videoPath: args[2], frameIndex: frameIndex)
      var i = 4
      while i < args.count {
        switch args[i] {
        case "--output-dir":
          guard i + 1 < args.count else { throw CLIError.missingArgument("--output-dir value") }
          options.outputDir = args[i + 1]
          i += 2
        case "--preprocess":
          options.preprocess = true
          i += 1
        case "--undistort":
          options.undistort = true
          i += 1
        case "--mosaic":
          options.mosaic = true
          i += 1
        case "--detect":
          options.detect = true
          i += 1
        case "--model":
          guard i + 1 < args.count else { throw CLIError.missingArgument("--model value") }
          options.modelPath = args[i + 1]
          i += 2
        case "--projection":
          guard i + 1 < args.count else { throw CLIError.missingArgument("--projection value") }
          options.undistortSettings = try makeProjectionSettings(name: args[i + 1])
          i += 2
        case "--tiles":
          guard i + 1 < args.count, let value = Int(args[i + 1]) else {
            throw CLIError.invalidValue(name: "--tiles", value: args[safe: i + 1] ?? "")
          }
          options.undistortSettings = try makeTileSettings(count: value)
          i += 2
        case "--tile-fov":
          guard i + 1 < args.count, let value = Float(args[i + 1]) else {
            throw CLIError.invalidValue(name: "--tile-fov", value: args[safe: i + 1] ?? "")
          }
          options.undistortSettings = overrideFov(options.undistortSettings, fov: value)
          i += 2
        case "--tile-size":
          guard i + 1 < args.count, let value = Int(args[i + 1]) else {
            throw CLIError.invalidValue(name: "--tile-size", value: args[safe: i + 1] ?? "")
          }
          options.undistortSettings = overrideSize(options.undistortSettings, size: value)
          i += 2
        default:
          throw CLIError.unknownCommand(args[i])
        }
      }
      return .extract(options)
    default:
      throw CLIError.unknownCommand(command)
    }
  }

  static func parseBatch(_ args: [String]) throws -> ParseResult {
    guard args.count >= 3 else { throw CLIError.missingArgument("video path") }
    guard args.count >= 4 else { throw CLIError.missingArgument("start frame") }
    guard args.count >= 5 else { throw CLIError.missingArgument("count") }
    guard let start = Int(args[3]) else { throw CLIError.invalidValue(name: "start", value: args[3]) }
    guard let count = Int(args[4]) else { throw CLIError.invalidValue(name: "count", value: args[4]) }

    var options = BatchOptions(videoPath: args[2], startFrame: start, count: count)
    var i = 5
    while i < args.count {
      switch args[i] {
      case "--output-dir":
        guard i + 1 < args.count else { throw CLIError.missingArgument("--output-dir value") }
        options.outputDir = args[i + 1]
        i += 2
      case "--preprocess":
        options.preprocess = true
        i += 1
      case "--projection":
        guard i + 1 < args.count else { throw CLIError.missingArgument("--projection value") }
        options.undistortSettings = try makeProjectionSettings(name: args[i + 1])
        i += 2
      case "--tiles":
        guard i + 1 < args.count, let value = Int(args[i + 1]) else {
          throw CLIError.invalidValue(name: "--tiles", value: args[safe: i + 1] ?? "")
        }
        options.undistortSettings = try makeTileSettings(count: value)
        i += 2
      default:
        throw CLIError.unknownCommand(args[i])
      }
    }
    return .batch(options)
  }

  static func makeTileSettings(count: Int) throws -> UndistortingModule.Settings {
    switch count {
    case 1: return .singleCenterTile
    case 2: return .twoTilesPerLens
    case 3: return .threeTilesPerLens
    default: throw CLIError.invalidValue(name: "--tiles", value: String(count))
    }
  }

  static func makeProjectionSettings(name: String) throws -> UndistortingModule.Settings {
    switch name {
    case "stereo", "stereographic":
      return .stereographicFullHemisphere
    case "equirect", "equirectangular":
      return .equirectangularFullHemisphere
    case "rect", "rectilinear":
      return .threeTilesPerLens
    default:
      throw CLIError.invalidValue(name: "--projection", value: name)
    }
  }

  static func overrideFov(_ settings: UndistortingModule.Settings, fov: Float) -> UndistortingModule.Settings {
    switch settings.projection {
    case .rectilinear(let tiles):
      let updated = tiles.map { tile in
        UndistortingModule.TileConfiguration(
          yawDegrees: tile.yawDegrees,
          pitchDegrees: tile.pitchDegrees,
          horizontalFieldOfViewDegrees: fov,
          outputWidth: tile.outputWidth,
          outputHeight: tile.outputHeight
        )
      }
      return UndistortingModule.Settings(projection: .rectilinear(tiles: updated))
    case .equirectangular(let config):
      let updated = UndistortingModule.EquirectConfiguration(
        outputWidth: config.outputWidth,
        outputHeight: config.outputHeight,
        horizontalFieldOfViewDegrees: fov,
        verticalFieldOfViewDegrees: fov
      )
      return UndistortingModule.Settings(projection: .equirectangular(updated))
    case .stereographic(let config):
      let updated = UndistortingModule.StereographicConfiguration(
        outputSize: config.outputSize,
        fieldOfViewDegrees: fov
      )
      return UndistortingModule.Settings(projection: .stereographic(updated))
    }
  }

  static func overrideSize(_ settings: UndistortingModule.Settings, size: Int) -> UndistortingModule.Settings {
    switch settings.projection {
    case .rectilinear(let tiles):
      let updated = tiles.map { tile in
        let aspect = Float(tile.outputHeight) / Float(tile.outputWidth)
        let newHeight = Int(Float(size) * aspect)
        return UndistortingModule.TileConfiguration(
          yawDegrees: tile.yawDegrees,
          pitchDegrees: tile.pitchDegrees,
          horizontalFieldOfViewDegrees: tile.horizontalFieldOfViewDegrees,
          outputWidth: size,
          outputHeight: newHeight
        )
      }
      return UndistortingModule.Settings(projection: .rectilinear(tiles: updated))
    case .equirectangular(let config):
      let updated = UndistortingModule.EquirectConfiguration(
        outputWidth: size,
        outputHeight: size,
        horizontalFieldOfViewDegrees: config.horizontalFieldOfViewDegrees,
        verticalFieldOfViewDegrees: config.verticalFieldOfViewDegrees
      )
      return UndistortingModule.Settings(projection: .equirectangular(updated))
    case .stereographic(let config):
      let updated = UndistortingModule.StereographicConfiguration(
        outputSize: size,
        fieldOfViewDegrees: config.fieldOfViewDegrees
      )
      return UndistortingModule.Settings(projection: .stereographic(updated))
    }
  }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

// JSON DTOs for detections.
struct DetectionsPayload: Encodable {
  let frame: Int
  let detections: [DetectionDTO]
}

struct DetectionDTO: Encodable {
  let objectClass: String
  let confidence: Float
  let bbox: BboxDTO
  let yawInLensDegrees: Float
  let pitchInLensDegrees: Float
  let estimatedDistanceMeters: Float
  let lens: String
  let sourceTileYawDegrees: Float
  let sourceTilePitchDegrees: Float

  struct BboxDTO: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
  }

  init(_ d: Detection) {
    self.objectClass = d.objectClass.rawValue
    self.confidence = d.confidence
    self.bbox = BboxDTO(
      x: Double(d.bbox.minX),
      y: Double(d.bbox.minY),
      width: Double(d.bbox.width),
      height: Double(d.bbox.height)
    )
    self.yawInLensDegrees = d.yawInLensDegrees
    self.pitchInLensDegrees = d.pitchInLensDegrees
    self.estimatedDistanceMeters = d.estimatedDistanceMeters
    self.lens = d.lens.rawValue
    self.sourceTileYawDegrees = d.sourceTileYawDegrees
    self.sourceTilePitchDegrees = d.sourceTilePitchDegrees
  }
}

// Draws bbox + class label + distance on top of a tile's pixel buffer and
// writes the result as a PNG, so a human can verify detections at a glance.
enum DetectionOverlayWriter {
  nonisolated(unsafe) private static let ciContext = CIContext()
  private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  // Colors per class — kept saturated so they pop against road footage.
  private static func color(for cls: DetectionClass) -> CGColor {
    switch cls {
    case .car: return CGColor(red: 0.20, green: 0.85, blue: 0.20, alpha: 1)
    case .truck, .bus: return CGColor(red: 0.20, green: 0.50, blue: 1.00, alpha: 1)
    case .person: return CGColor(red: 1.00, green: 0.25, blue: 0.25, alpha: 1)
    case .motorcycle, .bicycle: return CGColor(red: 1.00, green: 0.60, blue: 0.10, alpha: 1)
    case .trafficLight: return CGColor(red: 1.00, green: 1.00, blue: 0.30, alpha: 1)
    case .stopSign: return CGColor(red: 1.00, green: 0.10, blue: 0.10, alpha: 1)
    }
  }

  static func write(tile: Tile, detections: [Detection], to url: URL) throws {
    let frame = tile.frame
    let width = frame.width
    let height = frame.height

    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 4 * width,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw CLIError.invalidValue(name: "overlay", value: "CGContext creation failed")
    }

    // 1) draw the tile background
    let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
    guard let cgBackground = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
      throw CLIError.invalidValue(name: "overlay", value: "createCGImage failed")
    }
    context.draw(cgBackground, in: CGRect(x: 0, y: 0, width: width, height: height))

    // CGContext has bottom-left origin; our bbox.y is top-down. Flip vertically.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    for detection in detections {
      let pxBbox = CGRect(
        x: detection.bbox.minX * CGFloat(width),
        y: detection.bbox.minY * CGFloat(height),
        width: detection.bbox.width * CGFloat(width),
        height: detection.bbox.height * CGFloat(height)
      )
      let color = self.color(for: detection.objectClass)
      context.setStrokeColor(color)
      context.setLineWidth(4)
      context.stroke(pxBbox)

      let label = String(format: "%@ %.1fm", detection.objectClass.rawValue, detection.estimatedDistanceMeters)
      drawText(label, at: CGPoint(x: pxBbox.minX, y: pxBbox.maxY + 4),
               color: color, fontSize: 22, in: context, imageHeight: height)
    }

    guard let cgImage = context.makeImage() else {
      throw CLIError.invalidValue(name: "overlay", value: "context.makeImage() failed")
    }
    guard let dest = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
      throw CLIError.invalidValue(name: "overlay", value: "CGImageDestinationCreateWithURL failed")
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw CLIError.invalidValue(name: "overlay", value: "CGImageDestinationFinalize failed")
    }
  }

  // Draw text with a dark background box for readability. CoreText is the
  // simplest cross-platform-Apple option that doesn't pull in UIKit/AppKit.
  private static func drawText(
    _ string: String,
    at point: CGPoint,
    color: CGColor,
    fontSize: CGFloat,
    in context: CGContext,
    imageHeight: Int
  ) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
      kCTFontAttributeName: font,
      kCTForegroundColorAttributeName: color,
    ]
    guard let attrString = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary)
    else { return }
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, [])

    // Flip back to top-left for text positioning, then back to bottom-left
    // after drawing. Working in the flipped frame is just easier here.
    context.saveGState()
    // We are in top-down logical space (already flipped above). CoreText
    // draws bottom-up, so flip locally for this text only.
    context.translateBy(x: point.x, y: point.y + bounds.height)
    context.scaleBy(x: 1, y: -1)

    // Dark background pill
    let pad: CGFloat = 4
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
    context.fill(CGRect(x: -pad, y: -pad, width: bounds.width + 2 * pad, height: bounds.height + 2 * pad))

    context.textPosition = CGPoint(x: 0, y: 0)
    CTLineDraw(line, context)
    context.restoreGState()
  }
}

enum PNGWriter {
  // CIContext is documented thread-safe; the static cache is an unowned shared resource.
  nonisolated(unsafe) static let context = CIContext()
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  static func write(frame: Frame, to url: URL) throws {
    let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
    try context.writePNGRepresentation(
      of: ciImage,
      to: url,
      format: .RGBA8,
      colorSpace: colorSpace
    )
  }
}

// Stitches a set of tiles for a single lens into one PNG, laid out as a
// 2D grid by (yaw, pitch). Rows ordered with the highest pitch on top
// (sky tiles up, ground tiles down) to read like a normal panorama strip.
enum MosaicWriter {
  static func write(tiles: [Tile], to url: URL) throws {
    let yaws = Array(Set(tiles.map { $0.yawDegrees })).sorted()
    let pitches = Array(Set(tiles.map { $0.pitchDegrees })).sorted(by: >)

    let tileSize = tiles[0].frame.width
    let cols = yaws.count
    let rows = pitches.count
    let totalWidth = cols * tileSize
    let totalHeight = rows * tileSize

    guard let context = CGContext(
      data: nil,
      width: totalWidth,
      height: totalHeight,
      bitsPerComponent: 8,
      bytesPerRow: 4 * totalWidth,
      space: PNGWriter.colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw CLIError.invalidValue(name: "mosaic", value: "CGContext creation failed")
    }

    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

    for tile in tiles {
      guard let col = yaws.firstIndex(of: tile.yawDegrees),
            let row = pitches.firstIndex(of: tile.pitchDegrees) else { continue }

      let ciImage = CIImage(cvPixelBuffer: tile.frame.pixelBuffer)
      guard let cgImage = PNGWriter.context.createCGImage(ciImage, from: ciImage.extent) else { continue }

      // CGContext uses bottom-left origin; PNG semantics put row 0 on top.
      let cgY = totalHeight - (row + 1) * tileSize
      context.draw(cgImage, in: CGRect(x: col * tileSize, y: cgY, width: tileSize, height: tileSize))
    }

    guard let image = context.makeImage() else {
      throw CLIError.invalidValue(name: "mosaic", value: "context.makeImage() failed")
    }
    guard let dest = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
      throw CLIError.invalidValue(name: "mosaic", value: "CGImageDestinationCreateWithURL failed")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
      throw CLIError.invalidValue(name: "mosaic", value: "CGImageDestinationFinalize failed")
    }
  }
}
