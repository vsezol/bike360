import CoreMedia

public struct StereoFrame: @unchecked Sendable {
  public let front: Frame
  public let back: Frame
  public let sequenceNumber: UInt64

  public init(front: Frame, back: Frame, sequenceNumber: UInt64) {
    precondition(front.lens == .front, "front frame must have lens == .front")
    precondition(back.lens == .back, "back frame must have lens == .back")
    self.front = front
    self.back = back
    self.sequenceNumber = sequenceNumber
  }

  public var captureTimestamp: CMTime { front.timestamp }
}
