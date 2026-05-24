import CoreMedia

// One rectilinear "virtual camera" view extracted from a fisheye lens.
// The pipeline emits several Tiles per lens so that >180° coverage is
// preserved without the rectilinear FOV cap forcing us to drop edges.
public struct Tile: @unchecked Sendable {
  public let frame: Frame
  public let lens: Lens
  // Horizontal pan of this tile's optical axis relative to the lens axis,
  // in degrees. 0 == centered, negative == left, positive == right.
  public let yawDegrees: Float
  // Vertical tilt of this tile's optical axis relative to the lens axis,
  // in degrees. 0 == horizon, positive == aimed UP, negative == DOWN.
  public let pitchDegrees: Float

  public init(frame: Frame, lens: Lens, yawDegrees: Float, pitchDegrees: Float = 0) {
    self.frame = frame
    self.lens = lens
    self.yawDegrees = yawDegrees
    self.pitchDegrees = pitchDegrees
  }
}

// All rectilinear tiles for one stereo capture (front + back lens combined).
// Each tile is ready to be consumed independently by stage 2 (one YOLO
// instance per tile, with NMS across overlap zones).
public struct TiledFrame: @unchecked Sendable {
  public let tiles: [Tile]
  public let sequenceNumber: UInt64
  public let captureTimestamp: CMTime

  public init(tiles: [Tile], sequenceNumber: UInt64, captureTimestamp: CMTime) {
    self.tiles = tiles
    self.sequenceNumber = sequenceNumber
    self.captureTimestamp = captureTimestamp
  }

  public func tiles(for lens: Lens) -> [Tile] {
    tiles.filter { $0.lens == lens }
  }
}
