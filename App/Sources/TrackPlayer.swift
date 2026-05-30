import Foundation

// Drives playback of a TrackSession. Publishes the current frame on the
// main actor so SwiftUI (and through it, the SceneKit view) updates as
// playback advances. Timing follows each frame's timestamp delta, so the
// replay runs at the same rate the footage was captured. Loops forever —
// it's a demo reel.
@MainActor
final class TrackPlayer: ObservableObject {
  @Published private(set) var currentFrame: TrackFrame?
  @Published private(set) var frameIndex: Int = 0
  @Published private(set) var isPlaying: Bool = false
  // Playback rate. <1 = slow motion. The source footage is 60 fps, which
  // plays back in ~8 s — far too fast to read — so we slow it down by
  // default. Cycled via cycleSpeed().
  @Published private(set) var playbackSpeed: Double = 0.25

  let session: TrackSession
  private var task: Task<Void, Never>?

  init(session: TrackSession) {
    self.session = session
    self.currentFrame = session.frames.first
  }

  var frameCount: Int { session.frames.count }

  func play() {
    guard !isPlaying, !session.frames.isEmpty else { return }
    isPlaying = true
    task = Task { [weak self] in
      await self?.runLoop()
    }
  }

  func pause() {
    isPlaying = false
    task?.cancel()
    task = nil
  }

  func toggle() {
    isPlaying ? pause() : play()
  }

  func cycleSpeed() {
    switch playbackSpeed {
    case 0.25: playbackSpeed = 0.5
    case 0.5: playbackSpeed = 1.0
    default: playbackSpeed = 0.25
    }
  }

  private func runLoop() async {
    let frames = session.frames
    while !Task.isCancelled {
      var idx = 0
      while !Task.isCancelled && idx < frames.count {
        let frame = frames[idx]
        currentFrame = frame
        frameIndex = idx

        let nextIdx = idx + 1
        let dt: Double
        if nextIdx < frames.count {
          dt = max(0.001, frames[nextIdx].timestampSeconds - frame.timestampSeconds)
        } else {
          dt = 0.4  // brief pause before looping back to the start
        }
        // Divide by speed: 0.25 stretches each gap 4× (slow motion).
        let scaled = dt / max(0.05, playbackSpeed)
        try? await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
        idx = nextIdx
      }
    }
  }
}
