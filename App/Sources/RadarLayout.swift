import SceneKit
import UIKit
import Pipeline

// One object resolved to its final, ready-to-draw form. RadarScene consumes
// these and does nothing but create/move nodes — all geometry and collision
// math lives here.
struct PositionedRadarObject {
  let trackId: UInt64
  let position: SCNVector3   // collision-resolved, near-face-corrected
  let boxSize: SCNVector3
  let color: UIColor
  let label: String
}

// The compute layer between tracked data and the 3D view. Turns raw
// [TrackedObjectData] into collision-free [PositionedRadarObject].
//
// Layout is a force-directed relaxation that is STATEFUL and temporally
// coherent: every frame each object starts from its position in the previous
// frame and is nudged by two soft forces —
//   • attraction toward its "ideal" spot (on its view ray, near-face
//     corrected), so it tracks where the object really is, and
//   • repulsion from any overlapping neighbour, weighted by priority so the
//     closer (more important) object barely moves and the farther one yields.
// Because each frame starts from the last and only takes small steps, the
// output is continuous in the input — a tiny change in distances produces a
// tiny change on screen. That removes the swap/jitter you get from solving
// the packing from scratch every frame (which is discontinuous whenever the
// priority order flips).
//
// Used only from the main thread (SceneContainer.updateUIView), so the
// mutable caches need no synchronization.
final class RadarLayout {
  let appearance: ObjectAppearance

  // Clearance kept between object footprints, meters.
  private let margin: Float = 0.4
  // Relaxation tuning.
  private let iterations = 12
  private let attraction: Float = 0.25   // pull toward the true position
  // Sticky priority distance (for repulsion weighting only).
  private let orderingSmoothing: Float = 0.15

  // Per-track persistent state.
  private var displayPosition: [UInt64: SIMD2<Float>] = [:]
  private var orderingDistance: [UInt64: Float] = [:]

  init(appearance: ObjectAppearance) {
    self.appearance = appearance
  }

  private struct Item {
    let id: UInt64
    let ideal: SIMD2<Float>      // where the object truly is (on its ray)
    let footprint: Float
    let size: SCNVector3
    let color: UIColor
    let label: String
    var position: SIMD2<Float>   // working position during relaxation
    var priority: Float          // higher = closer = moves less
  }

  func positions(
    for objects: [TrackedObjectData],
    showUnreliable: Bool,
    maxRadius: Float
  ) -> [PositionedRadarObject] {
    let visible = objects.filter {
      (showUnreliable || $0.isReliable) && $0.estimatedDistanceMeters <= maxRadius
    }

    // Build items: ideal position (near-face corrected), footprint, priority.
    var items: [Item] = []
    items.reserveCapacity(visible.count)
    for object in visible {
      let size = appearance.boxSize(for: object.classLabel)
      let yawRad = object.yawInBikeDegrees * .pi / 180
      let dir = SIMD2<Float>(sin(yawRad), -cos(yawRad))  // forward = -Z

      // Near-face correction: box center sits half-extent beyond the reported
      // (near-face) distance along the ray.
      let halfExtent = (size.x / 2) * abs(sin(yawRad)) + (size.z / 2) * abs(cos(yawRad))
      let ideal = dir * (object.estimatedDistanceMeters + halfExtent)

      // Footprint as the AVERAGE half-extent (not the circumscribed circle),
      // so neighbours in adjacent lanes don't register false overlaps.
      let footprint = (size.x + size.z) / 4

      // Sticky ordering distance → priority (closer = higher, moves less).
      let prev = orderingDistance[object.trackId] ?? object.estimatedDistanceMeters
      let smoothed = prev + orderingSmoothing * (object.estimatedDistanceMeters - prev)
      orderingDistance[object.trackId] = smoothed
      let priority = 1.0 / max(0.5, smoothed)

      // Start from last frame's drawn position for temporal continuity;
      // new tracks appear directly at their ideal.
      let start = displayPosition[object.trackId] ?? ideal

      items.append(Item(
        id: object.trackId, ideal: ideal, footprint: footprint,
        size: size, color: appearance.color(for: object.classLabel),
        label: "#\(object.trackId) \(object.classLabel)",
        position: start, priority: priority
      ))
    }

    // Prune persistent state for tracks that are gone.
    let liveIds = Set(items.map(\.id))
    orderingDistance = orderingDistance.filter { liveIds.contains($0.key) }

    relax(&items)

    // Commit results + persist drawn positions.
    var nextDisplay: [UInt64: SIMD2<Float>] = [:]
    nextDisplay.reserveCapacity(items.count)
    var result: [PositionedRadarObject] = []
    result.reserveCapacity(items.count)
    for item in items {
      nextDisplay[item.id] = item.position
      result.append(PositionedRadarObject(
        trackId: item.id,
        position: SCNVector3(item.position.x, item.size.y / 2, item.position.y),
        boxSize: item.size,
        color: item.color,
        label: item.label
      ))
    }
    displayPosition = nextDisplay
    return result
  }

  // Force-directed relaxation: attract to ideal, repulse overlaps.
  private func relax(_ items: inout [Item]) {
    guard items.count > 1 else {
      if items.count == 1 { items[0].position = items[0].ideal }
      return
    }

    for _ in 0..<iterations {
      // 1. Attraction toward each object's true position.
      for i in items.indices {
        items[i].position += (items[i].ideal - items[i].position) * attraction
      }
      // 2. Pairwise repulsion for overlapping footprints, weighted by
      //    priority so the closer object barely moves.
      for i in 0..<(items.count - 1) {
        for j in (i + 1)..<items.count {
          let delta = items[i].position - items[j].position
          let distance = simd_length(delta)
          let required = items[i].footprint + items[j].footprint + margin
          guard distance < required else { continue }

          // Deterministic separation direction even if perfectly coincident.
          let dir: SIMD2<Float>
          if distance > 1e-4 {
            dir = delta / distance
          } else {
            let a = Float(i) * 2.399963  // golden angle, stable per-index
            dir = SIMD2<Float>(cos(a), sin(a))
          }
          let overlap = required - max(distance, 0)
          // Closer (higher priority) yields less.
          let total = items[i].priority + items[j].priority
          let wI = items[j].priority / total
          let wJ = items[i].priority / total
          items[i].position += dir * (overlap * wI)
          items[j].position -= dir * (overlap * wJ)
        }
      }
    }
  }
}
