import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Reads a dual-fisheye .insv file from an Insta360 camera. Each lens lives in
// its own HEVC video track inside the MP4 container, so AVAssetReader pulls
// them in parallel with no pixel-level splitting.
//
// Track ordering assumption: tracks[0] == front lens, tracks[1] == back lens.
// Empirically validated against the first frame the CLI extracts; an explicit
// override is exposed via lensOrder in case the assumption flips.
public final class InsvVideoSource: VideoSource {
  public enum LensOrder: Sendable {
    case frontFirst
    case backFirst
  }

  private let url: URL
  private let lensOrder: LensOrder

  public init(url: URL, lensOrder: LensOrder = .frontFirst) {
    self.url = url
    self.lensOrder = lensOrder
  }

  public func frames() -> AsyncThrowingStream<StereoFrame, any Error> {
    let url = self.url
    let lensOrder = self.lensOrder
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await Self.readLoop(url: url, lensOrder: lensOrder, continuation: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private static func readLoop(
    url: URL,
    lensOrder: LensOrder,
    continuation: AsyncThrowingStream<StereoFrame, any Error>.Continuation
  ) async throws {
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw VideoSourceError.fileNotReadable(path: url.path)
    }

    let asset = AVURLAsset(url: url)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)

    guard videoTracks.count >= 2 else {
      throw VideoSourceError.unexpectedTrackCount(expected: 2, actual: videoTracks.count)
    }

    let reader = try AVAssetReader(asset: asset)

    let pixelFormatSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]

    let outputs = videoTracks.prefix(2).map { track -> AVAssetReaderTrackOutput in
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: pixelFormatSettings)
      output.alwaysCopiesSampleData = true
      reader.add(output)
      return output
    }

    let (frontOutput, backOutput): (AVAssetReaderTrackOutput, AVAssetReaderTrackOutput) =
      switch lensOrder {
      case .frontFirst: (outputs[0], outputs[1])
      case .backFirst: (outputs[1], outputs[0])
      }

    guard reader.startReading() else {
      throw VideoSourceError.readerFailedToStart(underlying: reader.error)
    }

    let frontTrack = lensOrder == .frontFirst ? videoTracks[0] : videoTracks[1]
    let trackSize = try await frontTrack.load(.naturalSize)
    let imageSize = Int(trackSize.width)
    let intrinsics = CameraIntrinsics.insta360X3Default(imageSize: imageSize)

    var sequenceNumber: UInt64 = 0

    while !Task.isCancelled {
      guard
        let frontSample = frontOutput.copyNextSampleBuffer(),
        let backSample = backOutput.copyNextSampleBuffer()
      else {
        break
      }

      guard
        let frontBuffer = CMSampleBufferGetImageBuffer(frontSample),
        let backBuffer = CMSampleBufferGetImageBuffer(backSample)
      else {
        throw VideoSourceError.missingImageBuffer
      }

      let frontFrame = Frame(
        pixelBuffer: frontBuffer,
        timestamp: CMSampleBufferGetPresentationTimeStamp(frontSample),
        lens: .front,
        intrinsics: intrinsics
      )
      let backFrame = Frame(
        pixelBuffer: backBuffer,
        timestamp: CMSampleBufferGetPresentationTimeStamp(backSample),
        lens: .back,
        intrinsics: intrinsics
      )

      let stereo = StereoFrame(front: frontFrame, back: backFrame, sequenceNumber: sequenceNumber)
      sequenceNumber += 1

      continuation.yield(stereo)
    }

    if reader.status == .failed {
      throw VideoSourceError.readerFailed(underlying: reader.error)
    }
  }
}
