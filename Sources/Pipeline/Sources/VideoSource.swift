public protocol VideoSource: Sendable {
  func frames() -> AsyncThrowingStream<StereoFrame, any Error>
}

public enum VideoSourceError: Error, CustomStringConvertible {
  case unexpectedTrackCount(expected: Int, actual: Int)
  case readerFailedToStart(underlying: (any Error)?)
  case readerFailed(underlying: (any Error)?)
  case missingImageBuffer
  case fileNotReadable(path: String)

  public var description: String {
    switch self {
    case .unexpectedTrackCount(let expected, let actual):
      return "Expected \(expected) video tracks, got \(actual)"
    case .readerFailedToStart(let underlying):
      return "AVAssetReader.startReading() failed: \(underlying.map(String.init(describing:)) ?? "unknown")"
    case .readerFailed(let underlying):
      return "AVAssetReader failed: \(underlying.map(String.init(describing:)) ?? "unknown")"
    case .missingImageBuffer:
      return "CMSampleBuffer had no image buffer"
    case .fileNotReadable(let path):
      return "Video file not readable: \(path)"
    }
  }
}
