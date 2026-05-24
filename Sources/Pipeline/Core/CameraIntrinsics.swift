import Foundation

public struct CameraIntrinsics: Sendable, Hashable {
  public let focalLengthX: Float
  public let focalLengthY: Float
  public let principalPointX: Float
  public let principalPointY: Float
  public let distortionK1: Float
  public let distortionK2: Float
  public let distortionK3: Float
  public let distortionK4: Float
  public let fieldOfViewDegrees: Float
  public let imageWidth: Int
  public let imageHeight: Int

  public init(
    focalLengthX: Float,
    focalLengthY: Float,
    principalPointX: Float,
    principalPointY: Float,
    distortionK1: Float = 0,
    distortionK2: Float = 0,
    distortionK3: Float = 0,
    distortionK4: Float = 0,
    fieldOfViewDegrees: Float,
    imageWidth: Int,
    imageHeight: Int
  ) {
    self.focalLengthX = focalLengthX
    self.focalLengthY = focalLengthY
    self.principalPointX = principalPointX
    self.principalPointY = principalPointY
    self.distortionK1 = distortionK1
    self.distortionK2 = distortionK2
    self.distortionK3 = distortionK3
    self.distortionK4 = distortionK4
    self.fieldOfViewDegrees = fieldOfViewDegrees
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
  }
}

extension CameraIntrinsics {
  // Approximate defaults for an Insta360 X3 fisheye lens (square 1:1 image, ~190° FOV).
  // Real per-lens calibration via chessboard will come later.
  public static func insta360X3Default(imageSize: Int) -> CameraIntrinsics {
    let fovDegrees: Float = 190.0
    let fovRadians = fovDegrees * .pi / 180.0
    let halfImage = Float(imageSize) / 2.0
    // Equidistant fisheye projection: r = f * theta, so f = r_max / (fov/2)
    let focal = halfImage / (fovRadians / 2.0)
    return CameraIntrinsics(
      focalLengthX: focal,
      focalLengthY: focal,
      principalPointX: halfImage,
      principalPointY: halfImage,
      fieldOfViewDegrees: fovDegrees,
      imageWidth: imageSize,
      imageHeight: imageSize
    )
  }
}
