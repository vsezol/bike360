import SceneKit

// Converts a bike-frame polar direction + distance into a SceneKit
// world position.
//
// Bike-frame convention (identical to Pipeline's WorldDetection):
//   yaw:   0 = forward, +90 = right, -90 = left, ±180 = behind
//   pitch: 0 = horizon, + = above horizon
//
// SceneKit axes: +X right, +Y up, +Z toward the viewer. So "forward"
// (yaw 0) maps to -Z, and "right" (yaw +90) maps to +X.
enum PolarProjection {
  static func groundPosition(
    yawDegrees: Float,
    pitchDegrees: Float,
    distanceMeters: Float,
    flattenToGround: Bool = true
  ) -> SCNVector3 {
    let yaw = yawDegrees * .pi / 180
    let pitch = pitchDegrees * .pi / 180
    let horizontal = distanceMeters * cos(pitch)
    let x = horizontal * sin(yaw)
    let z = -horizontal * cos(yaw)
    let y = flattenToGround ? 0 : distanceMeters * sin(pitch)
    return SCNVector3(x, y, z)
  }
}
