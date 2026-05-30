import SceneKit
import UIKit

// Builds and maintains the 3D radar scene. Static geometry (ground grid,
// distance rings, rider marker, lights, cameras) is built once. Per frame,
// `update(with:)` reconciles the set of object boxes against the tracked
// objects, keyed by trackId — so a box keeps its identity and animates
// smoothly to its new position instead of blinking.
@MainActor
final class RadarScene {
  let scene = SCNScene()

  // User-controlled orbit camera and fixed Tesla-style chase camera.
  let orbitCameraNode = SCNNode()
  let chaseCameraNode = SCNNode()

  private let objectsRoot = SCNNode()
  // Grid + distance rings live here so they can be torn down and rebuilt
  // when the radius changes at runtime.
  private let scalableRoot = SCNNode()
  private var nodes: [UInt64: SCNNode] = [:]
  // Radius drives only the rings/grid/camera here; object positions and the
  // distance cutoff are computed upstream in RadarLayout. Mutable so the UI
  // can switch 10/25/50 m live.
  private var maxRadius: Float

  init(maxRadiusMeters: Float) {
    self.maxRadius = maxRadiusMeters
    buildStaticScene()
  }

  // MARK: - Static scene

  private func buildStaticScene() {
    scene.background.contents = UIColor(white: 0.04, alpha: 1)
    scene.rootNode.addChildNode(objectsRoot)
    scene.rootNode.addChildNode(scalableRoot)

    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light?.type = .ambient
    ambient.light?.intensity = 500
    ambient.light?.color = UIColor(white: 0.7, alpha: 1)
    scene.rootNode.addChildNode(ambient)

    let sun = SCNNode()
    sun.light = SCNLight()
    sun.light?.type = .directional
    sun.light?.intensity = 900
    sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
    scene.rootNode.addChildNode(sun)

    addRiderMarker()
    setupCameras()
    rebuildScalable()
  }

  // Rebuilds the radius-dependent geometry (grid + rings) and repositions
  // the cameras. Called on init and whenever the radius changes.
  private func rebuildScalable() {
    scalableRoot.childNodes.forEach { $0.removeFromParentNode() }
    addGroundGrid(halfExtent: maxRadius * 1.15, step: max(5, (maxRadius / 5).rounded()))
    for radius in ringRadii() {
      addDistanceRing(radiusMeters: radius)
    }
    updateCameraForRadius()
  }

  // Switch the display radius at runtime (UI 10/25/50 m). Rebuilds rings,
  // grid and cameras; objects beyond the new radius are culled on the next
  // update(with:).
  func setRadius(_ newRadius: Float) {
    guard newRadius != maxRadius else { return }
    maxRadius = newRadius
    rebuildScalable()
  }

  private func updateCameraForRadius() {
    let farPlane = Double(max(600, maxRadius * 8))
    orbitCameraNode.camera?.zFar = farPlane
    // Pull back proportionally to the radius so the whole visible disc fits.
    orbitCameraNode.position = SCNVector3(0, maxRadius * 1.05, maxRadius * 0.85)
    orbitCameraNode.look(at: SCNVector3(0, 0, 0))
    chaseCameraNode.camera?.zFar = farPlane
  }

  // Nice round rings up to the configured radius, plus the boundary ring
  // exactly at maxRadius so the edge of the visible world is explicit.
  private func ringRadii() -> [Float] {
    let candidates: [Float] = [10, 25, 50, 75, 100, 150, 200, 300]
    var rings = candidates.filter { $0 <= maxRadius }
    if rings.last != maxRadius {
      rings.append(maxRadius)
    }
    return rings
  }

  private func addGroundGrid(halfExtent: Float = 60, step: Float = 10) {
    var vertices: [SCNVector3] = []
    var v = -halfExtent
    while v <= halfExtent + 0.001 {
      vertices.append(SCNVector3(-halfExtent, 0, v))
      vertices.append(SCNVector3(halfExtent, 0, v))
      vertices.append(SCNVector3(v, 0, -halfExtent))
      vertices.append(SCNVector3(v, 0, halfExtent))
      v += step
    }
    let node = SCNNode(geometry: lineGeometry(vertices: vertices, color: UIColor(white: 0.3, alpha: 1)))
    scalableRoot.addChildNode(node)
  }

  private func addDistanceRing(radiusMeters radius: Float, segments: Int = 72) {
    var vertices: [SCNVector3] = []
    for i in 0..<segments {
      let a0 = Float(i) / Float(segments) * 2 * .pi
      let a1 = Float(i + 1) / Float(segments) * 2 * .pi
      vertices.append(SCNVector3(radius * cos(a0), 0.02, radius * sin(a0)))
      vertices.append(SCNVector3(radius * cos(a1), 0.02, radius * sin(a1)))
    }
    let color = UIColor(red: 0.2, green: 0.55, blue: 0.85, alpha: 1)
    let ring = SCNNode(geometry: lineGeometry(vertices: vertices, color: color))
    scalableRoot.addChildNode(ring)

    // distance label on the forward (-Z) side of the ring
    let label = makeBillboardLabel("\(Int(radius))m", color: color, scale: 0.5)
    label.position = SCNVector3(0, 0.5, -radius)
    scalableRoot.addChildNode(label)
  }

  private func addRiderMarker() {
    let rider = SCNNode()

    let body = SCNBox(width: 0.5, height: 1.0, length: 1.9, chamferRadius: 0.12)
    let bodyMat = SCNMaterial()
    bodyMat.diffuse.contents = UIColor.cyan
    bodyMat.lightingModel = .constant
    body.materials = [bodyMat]
    let bodyNode = SCNNode(geometry: body)
    bodyNode.position = SCNVector3(0, 0.5, 0)
    rider.addChildNode(bodyNode)

    // Forward-pointing cone (heading indicator), aimed at -Z.
    let cone = SCNCone(topRadius: 0, bottomRadius: 0.32, height: 0.9)
    let coneMat = SCNMaterial()
    coneMat.diffuse.contents = UIColor.cyan
    coneMat.lightingModel = .constant
    cone.materials = [coneMat]
    let coneNode = SCNNode(geometry: cone)
    coneNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)  // +Y tip -> -Z
    coneNode.position = SCNVector3(0, 0.5, -1.5)
    rider.addChildNode(coneNode)

    // Vertical beacon: the rider sits at the scene origin and gets buried
    // under nearby boxes, so a tall thin pole keeps "where am I" always
    // visible regardless of camera angle.
    let beacon = SCNCylinder(radius: 0.07, height: 8)
    let beaconMat = SCNMaterial()
    beaconMat.diffuse.contents = UIColor.cyan
    beaconMat.lightingModel = .constant
    beacon.materials = [beaconMat]
    let beaconNode = SCNNode(geometry: beacon)
    beaconNode.position = SCNVector3(0, 4, 0)
    rider.addChildNode(beaconNode)

    scene.rootNode.addChildNode(rider)
  }

  private func setupCameras() {
    // Camera position / zFar are set by updateCameraForRadius() so they
    // follow the active radius; here we just create the nodes once.
    let orbit = SCNCamera()
    orbit.fieldOfView = 60
    orbitCameraNode.camera = orbit
    scene.rootNode.addChildNode(orbitCameraNode)

    // Tesla-style 3rd-person chase: behind the rider (+Z), above, looking
    // forward down the road (-Z).
    let chase = SCNCamera()
    chase.fieldOfView = 55
    chaseCameraNode.camera = chase
    chaseCameraNode.position = SCNVector3(0, 7, 16)
    chaseCameraNode.look(at: SCNVector3(0, 1, -22))
    scene.rootNode.addChildNode(chaseCameraNode)
  }

  // MARK: - Per-frame update

  // Pure render: reconcile the node set against pre-computed, collision-free
  // positions from RadarLayout. No geometry/collision math here — this module
  // only draws.
  func render(_ objects: [PositionedRadarObject]) {
    var seen = Set<UInt64>()

    for object in objects {
      seen.insert(object.trackId)

      let node: SCNNode
      let isNewNode: Bool
      if let existing = nodes[object.trackId] {
        node = existing
        isNewNode = false
      } else {
        node = makeNode(for: object)
        nodes[object.trackId] = node
        objectsRoot.addChildNode(node)
        isNewNode = true
      }

      if isNewNode {
        // First appearance: drop straight onto position so it doesn't fly in
        // from the scene origin (0,0,0) under the rider.
        node.position = object.position
      } else {
        // Existing track: glide so motion stays smooth.
        node.runAction(SCNAction.move(to: object.position, duration: 0.1))
      }
      // Boxes stay aligned to our heading — no reliable per-object yaw yet
      // (needs an ML orientation head; see RadarLayout notes).
      node.eulerAngles = SCNVector3Zero
    }

    for (id, node) in nodes where !seen.contains(id) {
      node.removeFromParentNode()
      nodes.removeValue(forKey: id)
    }
  }

  // MARK: - Node construction

  private func makeNode(for object: PositionedRadarObject) -> SCNNode {
    let size = object.boxSize
    let box = SCNBox(
      width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z),
      chamferRadius: 0.06
    )
    let material = SCNMaterial()
    material.diffuse.contents = object.color
    material.transparency = 0.88
    box.materials = [material]

    let node = SCNNode(geometry: box)

    let label = makeBillboardLabel(object.label, color: .white, scale: 0.35)
    label.position = SCNVector3(0, Float(size.y) / 2 + 0.7, 0)
    node.addChildNode(label)

    return node
  }

  // MARK: - Helpers

  private func lineGeometry(vertices: [SCNVector3], color: UIColor) -> SCNGeometry {
    let source = SCNGeometrySource(vertices: vertices)
    let indices = (0..<Int32(vertices.count)).map { $0 }
    let element = SCNGeometryElement(indices: indices, primitiveType: .line)
    let geometry = SCNGeometry(sources: [source], elements: [element])
    let material = SCNMaterial()
    material.diffuse.contents = color
    material.lightingModel = .constant
    geometry.materials = [material]
    return geometry
  }

  private func makeBillboardLabel(_ string: String, color: UIColor, scale: Float) -> SCNNode {
    let text = SCNText(string: string, extrusionDepth: 0)
    text.font = .systemFont(ofSize: 4, weight: .semibold)
    text.flatness = 0.4
    let material = SCNMaterial()
    material.diffuse.contents = color
    material.lightingModel = .constant
    text.materials = [material]

    let node = SCNNode(geometry: text)
    node.scale = SCNVector3(scale, scale, scale)

    // Center the text horizontally on its anchor.
    let (minBound, maxBound) = text.boundingBox
    let dx = (maxBound.x - minBound.x) / 2 + minBound.x
    node.pivot = SCNMatrix4MakeTranslation(dx, 0, 0)

    let billboard = SCNBillboardConstraint()
    billboard.freeAxes = .Y
    node.constraints = [billboard]
    return node
  }
}
