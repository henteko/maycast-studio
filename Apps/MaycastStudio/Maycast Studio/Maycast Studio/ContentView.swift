import SwiftUI
import MaycastCore

struct ContentView: View {
    @Environment(EpisodeStore.self) private var store

    var body: some View {
        Group {
            if let bundle = store.bundle {
                EpisodeView(bundle: bundle)
            } else if let error = store.errorMessage {
                ErrorView(message: error) { store.close() }
            } else {
                EmptyStateView { store.openWithPanel() }
            }
        }
    }
}

struct EpisodeView: View {
    let bundle: EpisodeBundle
    @Environment(EpisodeStore.self) private var store
    @State private var showingPolish: Bool = false
    @State private var showingMix: Bool = false
    @State private var showingEditor: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(bundle.episode.id).font(.title.bold())
                Spacer()
                Text(bundle.episode.uuid.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let show = bundle.episode.show {
                Label(show, systemImage: "shippingbox")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(bundle.url.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            if bundle.episode.tracks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No tracks yet")
                        .font(.headline)
                    Text("Run `maycast import` to add audio sources.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(bundle.episode.tracks) { track in
                            TrackRow(track: track)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.background.secondary)
                                )
                        }
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Button { showingEditor = true } label: {
                        Label("Slice (multi-track)", systemImage: "scissors")
                    }
                    .buttonStyle(.bordered)

                    Button { showingPolish = true } label: {
                        Label("Polish (multi-track)", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)

                    Button { showingMix = true } label: {
                        Label("Mix", systemImage: "square.stack.3d.down.forward")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .padding()
        .sheet(isPresented: $showingPolish) {
            PolishSheet(bundle: bundle) { store.open(at: bundle.url) }
        }
        .sheet(isPresented: $showingMix) {
            MixSheet(bundle: bundle) { store.open(at: bundle.url) }
        }
        .sheet(isPresented: $showingEditor) {
            EditorSheet(bundle: bundle) { store.open(at: bundle.url) }
        }
    }
}

struct TrackRow: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.id).font(.headline)
            label("source",  track.source)
            label("current", track.current)
            Text("\(track.history.count) generation(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(key):")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
        }
    }
}

struct EmptyStateView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Episode open").font(.title2)
            Text("Open a .maycast bundle to inspect its tracks.")
                .foregroundStyle(.secondary)
            Button("Open Episode…", action: onOpen)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Failed to open Episode").font(.headline)
            Text(message)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 500)
            Button("Dismiss", action: onDismiss)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview Samples

#if DEBUG
extension Track {
    static var sampleHost: Track {
        Track(
            id: "host",
            source: "sources/host.wav",
            current: "intermediate/host/003_polish.wav",
            history: [
                "intermediate/host/001_import.wav",
                "intermediate/host/002_slice.wav",
                "intermediate/host/003_polish.wav",
            ]
        )
    }

    static var sampleGuest: Track {
        Track(
            id: "guest",
            source: "sources/guest.wav",
            current: "intermediate/guest/001_import.wav",
            history: ["intermediate/guest/001_import.wav"]
        )
    }
}

extension EpisodeBundle {
    static var sampleWithTracks: EpisodeBundle {
        EpisodeBundle(
            url: URL(fileURLWithPath: "/tmp/demo.maycast"),
            episode: Episode(
                id: "ep01",
                show: "../",
                tracks: [.sampleHost, .sampleGuest]
            )
        )
    }

    static var sampleEmpty: EpisodeBundle {
        EpisodeBundle(
            url: URL(fileURLWithPath: "/tmp/empty.maycast"),
            episode: Episode(id: "empty")
        )
    }
}
#endif

#Preview("Empty State") {
    ContentView()
        .environment(EpisodeStore())
}

#Preview("With Tracks") {
    let store = EpisodeStore()
    store.bundle = .sampleWithTracks
    return ContentView().environment(store)
}

#Preview("No Tracks") {
    let store = EpisodeStore()
    store.bundle = .sampleEmpty
    return ContentView().environment(store)
}

#Preview("Error State") {
    let store = EpisodeStore()
    store.errorMessage = "Manifest not found at /tmp/missing.maycast/episode.json"
    return ContentView().environment(store)
}

#Preview("TrackRow") {
    TrackRow(track: .sampleHost)
        .padding()
}
