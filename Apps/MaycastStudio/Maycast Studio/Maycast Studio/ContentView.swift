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
                .frame(maxHeight: .infinity)

                Divider()
                RecentActivityPanel(bundle: bundle)
                Divider()

                HStack(spacing: 12) {
                    Button { store.undo() } label: {
                        Label(undoButtonLabel, systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.canUndo)
                    .help(store.canUndo ? "Undo the most recent operation (⌘Z)" : "Nothing to undo")

                    if store.canRedo {
                        Button { store.redo() } label: {
                            Label("Redo", systemImage: "arrow.uturn.forward")
                        }
                        .buttonStyle(.bordered)
                        .help("Re-apply the most recently undone operation (⇧⌘Z)")
                    }

                    Divider().frame(height: 22)

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

    /// Label for the Undo button — shows the kind of the next batch that
    /// would be reverted, so the user knows what they're about to undo.
    private var undoButtonLabel: String {
        if let lastKind = bundle.episode.operations.last?.kind {
            return "Undo \(lastKind)"
        }
        return "Undo"
    }
}

// MARK: - Recent activity panel

/// Compact list of the most recent operation batches, embedded in the main
/// episode view. "Show all…" opens the full history sheet.
struct RecentActivityPanel: View {
    let bundle: EpisodeBundle
    @Environment(EpisodeStore.self) private var store

    private let maxRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Recent activity", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                if totalBatchCount > 0 {
                    Text("(\(totalBatchCount) total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show all…") { store.isShowingHistory = true }
                    .buttonStyle(.borderless)
                    .disabled(totalBatchCount == 0 && undoneBatchCount == 0)
            }
            if appliedBatches.isEmpty && undoneBatchCount == 0 {
                Text("No operations recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(appliedBatches.prefix(maxRows).map { $0 }) { batch in
                    CompactBatchRow(batch: batch, style: .applied)
                }
                if undoneBatchCount > 0, appliedBatches.count < maxRows,
                   let nextRedo = undoneBatchesReversed.first {
                    CompactBatchRow(batch: nextRedo, style: .undone)
                }
            }
        }
    }

    private var appliedBatches: [HistoryBatch] {
        groupByBatch(bundle.episode.operations).reversed()
    }

    private var undoneBatchesReversed: [HistoryBatch] {
        groupByBatch(bundle.episode.undone).reversed()
    }

    private var totalBatchCount: Int { groupByBatch(bundle.episode.operations).count }
    private var undoneBatchCount: Int { groupByBatch(bundle.episode.undone).count }
}

private struct CompactBatchRow: View {
    let batch: HistoryBatch
    let style: Style

    enum Style { case applied, undone }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(iconColor).frame(width: 18)
            Text(batch.kind.capitalized).font(.callout.weight(.medium))
            Text(batch.trackSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if style == .undone {
                Text("(undone)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(batch.timestamp, style: .relative)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .opacity(style == .undone ? 0.55 : 1.0)
    }

    private var icon: String {
        switch batch.kind {
        case "slice": return "scissors"
        case "polish": return "wand.and.sparkles"
        case "mix": return "rectangle.stack"
        default: return "circle.fill"
        }
    }

    private var iconColor: Color {
        style == .applied ? .accentColor : .secondary
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
        var episode = Episode(
            id: "ep01",
            show: "../",
            tracks: [.sampleHost, .sampleGuest]
        )
        let now = Date()
        let slice = UUID().uuidString
        let polish = UUID().uuidString
        episode.operations = [
            OperationLogEntry(
                batchID: slice, kind: "slice", trackID: "host",
                from: "intermediate/host/001_import.wav",
                to: "intermediate/host/002_slice.wav",
                timestamp: now.addingTimeInterval(-180)
            ),
            OperationLogEntry(
                batchID: slice, kind: "slice", trackID: "guest",
                from: "intermediate/guest/001_import.wav",
                to: "intermediate/guest/002_slice.wav",
                timestamp: now.addingTimeInterval(-180)
            ),
            OperationLogEntry(
                batchID: polish, kind: "polish", trackID: "host",
                from: "intermediate/host/002_slice.wav",
                to: "intermediate/host/003_polish.wav",
                timestamp: now.addingTimeInterval(-25)
            ),
            OperationLogEntry(
                batchID: polish, kind: "polish", trackID: "guest",
                from: "intermediate/guest/002_slice.wav",
                to: "intermediate/guest/003_polish.wav",
                timestamp: now.addingTimeInterval(-25)
            ),
        ]
        return EpisodeBundle(
            url: URL(fileURLWithPath: "/tmp/demo.maycast"),
            episode: episode
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
