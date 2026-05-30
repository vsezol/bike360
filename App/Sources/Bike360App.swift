import SwiftUI
import Pipeline

@main
struct Bike360App: App {
  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}

// Loads the recorded track + detection config from the bundle, then hands
// off to the radar view. Surfaces load errors instead of crashing so a
// missing/renamed resource is obvious on device.
struct RootView: View {
  private enum LoadState {
    case loading
    case ready(TrackSession, DetectionConfig)
    case failed(String)
  }

  @State private var state: LoadState = .loading

  var body: some View {
    switch state {
    case .loading:
      ProgressView("Loading track…")
        .task { load() }
    case .ready(let session, let config):
      RadarView(session: session, config: config)
    case .failed(let message):
      VStack(spacing: 12) {
        Image(systemName: "exclamationmark.triangle")
          .font(.largeTitle)
          .foregroundColor(.orange)
        Text("Failed to load")
          .font(.headline)
        Text(message)
          .font(.caption)
          .multilineTextAlignment(.center)
          .foregroundColor(.secondary)
      }
      .padding()
    }
  }

  private func load() {
    do {
      let session = try TrackSession.loadFromBundle(named: "track")
      let config = try loadConfig()
      state = .ready(session, config)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  private func loadConfig() throws -> DetectionConfig {
    guard let url = Bundle.main.url(forResource: "detection-classes", withExtension: "json") else {
      throw NSError(
        domain: "Bike360", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "detection-classes.json not found in app bundle"]
      )
    }
    return try DetectionConfig.load(from: url)
  }
}
