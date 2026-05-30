import SwiftUI
import SceneKit
import UIKit
import Pipeline

// The main screen: a SceneKit radar view with a HUD overlay and a compact,
// horizontally-scrolling control bar pinned to the bottom. In debug
// "Camera" mode the screen splits — 3D map on top, the per-frame detection
// mosaic on the bottom, both driven by the same frameIndex so they're synced.
struct RadarView: View {
  enum CameraMode {
    case orbit
    case chase
  }

  @StateObject private var player: TrackPlayer
  @State private var cameraMode: CameraMode = .orbit
  @State private var showUnreliable = false
  @State private var showCamera = false
  @State private var radiusMeters: Float

  private let radarScene: RadarScene
  private let radarLayout: RadarLayout

  init(session: TrackSession, config: DetectionConfig) {
    let radarConfig = RadarConfig.loadFromBundle()
    _player = StateObject(wrappedValue: TrackPlayer(session: session))
    _radiusMeters = State(initialValue: radarConfig.maxDisplayRadiusMeters)
    radarLayout = RadarLayout(appearance: ObjectAppearance(config: config))
    radarScene = RadarScene(maxRadiusMeters: radarConfig.maxDisplayRadiusMeters)
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .top) {
        VStack(spacing: 0) {
          SceneContainer(
            scene: radarScene,
            layout: radarLayout,
            player: player,
            cameraMode: cameraMode,
            showUnreliable: showUnreliable,
            radiusMeters: radiusMeters
          )
          .frame(height: showCamera ? geo.size.height * 0.5 : geo.size.height)

          if showCamera {
            CameraStripView(frameNumber: player.currentFrame?.frameNumber ?? 0)
              .frame(width: geo.size.width, height: geo.size.height * 0.5)
              .clipped()
              .background(Color.black)
          }
        }

        VStack {
          statusPanel
          Spacer()
          controlBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
      }
    }
    .ignoresSafeArea()
    .onAppear { player.play() }
  }

  private var statusPanel: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("frame \(player.frameIndex + 1) / \(player.frameCount)")
        Text("objects: \(visibleCount)")
      }
      .font(.system(.caption2, design: .monospaced))
      .foregroundColor(.white)
      .padding(6)
      .background(.black.opacity(0.55))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      Spacer()
    }
  }

  // Compact, horizontally-scrolling control bar pinned to the bottom.
  private var controlBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        pill(player.isPlaying ? "pause.fill" : "play.fill",
             player.isPlaying ? "Pause" : "Play", on: true) { player.toggle() }
        pill("speedometer", speedLabel, on: true) { player.cycleSpeed() }
        pill("scope", "\(Int(radiusMeters))m", on: true) { cycleRadius() }
        pill("camera.rotate", cameraMode == .orbit ? "Chase" : "Orbit", on: true) {
          cameraMode = (cameraMode == .orbit) ? .chase : .orbit
        }
        pill("rectangle.split.1x2", "Camera", on: showCamera) { showCamera.toggle() }
        pill("eye", "All", on: showUnreliable) { showUnreliable.toggle() }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
    }
    .background(.black.opacity(0.4))
    .clipShape(Capsule())
  }

  // One pill button: icon + small label, single line, sized to content.
  private func pill(_ icon: String, _ text: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: icon)
        Text(text)
      }
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .fixedSize()
      .foregroundColor(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(on ? Color.blue : Color.white.opacity(0.18))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private var visibleCount: Int {
    guard let objects = player.currentFrame?.objects else { return 0 }
    return showUnreliable ? objects.count : objects.filter(\.isReliable).count
  }

  private var speedLabel: String {
    let speed = player.playbackSpeed
    return speed == 1.0 ? "1x" : String(format: "%.2gx", speed)
  }

  // Cycle the display radius through the three presets the user asked for.
  private func cycleRadius() {
    switch radiusMeters {
    case 10: radiusMeters = 25
    case 25: radiusMeters = 50
    default: radiusMeters = 10
    }
  }
}

// Bottom-half "camera" strip: the per-frame detection mosaic (frame_NNNNNN.jpg
// in the bundle), looked up by the same frame number that drives the map.
struct CameraStripView: View {
  let frameNumber: Int

  var body: some View {
    if let image = Self.load(frameNumber) {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ZStack {
        Color.black
        Text("no camera frame \(frameNumber)")
          .font(.caption)
          .foregroundColor(.gray)
      }
    }
  }

  private static func load(_ number: Int) -> UIImage? {
    let name = String(format: "frame_%06d", number)
    guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
    return UIImage(contentsOfFile: url.path)
  }
}

// Bridges the UIKit SCNView into SwiftUI. updateUIView fires whenever the
// observed player publishes a new frame (or a control toggles): it computes
// collision-free positions and hands them to the renderer.
struct SceneContainer: UIViewRepresentable {
  let scene: RadarScene
  let layout: RadarLayout
  @ObservedObject var player: TrackPlayer
  let cameraMode: RadarView.CameraMode
  let showUnreliable: Bool
  let radiusMeters: Float

  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = scene.scene
    view.backgroundColor = UIColor(white: 0.04, alpha: 1)
    view.antialiasingMode = .multisampling2X
    applyCamera(to: view)
    return view
  }

  func updateUIView(_ view: SCNView, context: Context) {
    scene.setRadius(radiusMeters)
    applyCamera(to: view)
    if let frame = player.currentFrame {
      let positioned = layout.positions(
        for: frame.objects,
        showUnreliable: showUnreliable,
        maxRadius: radiusMeters
      )
      scene.render(positioned)
    }
  }

  private func applyCamera(to view: SCNView) {
    switch cameraMode {
    case .orbit:
      view.allowsCameraControl = true
      view.pointOfView = scene.orbitCameraNode
    case .chase:
      view.allowsCameraControl = false
      view.pointOfView = scene.chaseCameraNode
    }
  }
}
