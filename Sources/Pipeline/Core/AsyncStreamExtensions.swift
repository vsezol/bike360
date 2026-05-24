extension AsyncStream {
  // Newest-wins buffering with a small capacity. Old elements are dropped
  // if the consumer falls behind — matches AVCaptureVideoDataOutput semantics
  // for real-time video.
  public static func bufferingNewest(
    _ count: Int = 1
  ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
    var capturedContinuation: AsyncStream<Element>.Continuation!
    let stream = AsyncStream<Element>(
      bufferingPolicy: .bufferingNewest(count)
    ) { continuation in
      capturedContinuation = continuation
    }
    return (stream, capturedContinuation)
  }
}
