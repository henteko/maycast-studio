import SwiftUI
import MaycastCore

struct ContentView: View {
    @Environment(EpisodeStore.self) private var store
    @State private var showingNewEpisode: Bool = false
    @State private var showingNewShow: Bool = false
    @State private var newEpisodeForm = NewEpisodeForm()
    @State private var newShowForm = NewShowForm()
    @State private var newEpisodeError: String?
    @State private var newShowError: String?
    @State private var isCreatingEpisode: Bool = false
    @State private var isCreatingShow: Bool = false

    var body: some View {
        Group {
            if let bundle = store.bundle {
                EpisodeView(bundle: bundle)
            } else if let error = store.errorMessage {
                ErrorView(message: error) { store.close() }
            } else {
                HomeView(
                    recents: store.recents,
                    onNewEpisode: { presentNewEpisode() },
                    onNewShow: { presentNewShow() },
                    onOpen: { store.openWithPanel() },
                    onSelectRecent: { recent in store.openRecent(recent) },
                    onForgetRecent: { recent in store.forgetRecent(recent) }
                )
            }
        }
        .sheet(isPresented: $showingNewEpisode) {
            NewEpisodeSheet(
                form: $newEpisodeForm,
                validationError: newEpisodeError,
                isCreating: isCreatingEpisode,
                creatingStage: store.createStage,
                availableShows: store.availableShows,
                onPickShow: { pickShowForEpisode() },
                onClearShow: {
                    newEpisodeForm.attachedShowPath = nil
                    newEpisodeForm.attachedShowName = nil
                },
                onSelectShow: { choice in attachShow(path: choice.path, name: choice.name) },
                onDropShowFile: { url in
                    if let choice = store.showChoice(forDroppedShowAt: url) {
                        attachShow(path: choice.path, name: choice.name)
                    }
                },
                onPickSpeakerAudio: { speakerID in pickSpeakerAudio(speakerID: speakerID) },
                onDropSpeakerAudio: { speakerID, url in
                    if let idx = newEpisodeForm.speakers.firstIndex(where: { $0.id == speakerID }) {
                        newEpisodeForm.speakers[idx].audioPath = url.path
                    }
                },
                onCreate: { _ in createEpisode() }
            )
        }
        .sheet(isPresented: $showingNewShow) {
            NewShowSheet(
                form: $newShowForm,
                validationError: newShowError,
                isCreating: isCreatingShow,
                onPickIntro: { newShowForm.introPath = store.pickAudioFile(prompt: "Select intro audio")?.path ?? newShowForm.introPath },
                onPickOutro: { newShowForm.outroPath = store.pickAudioFile(prompt: "Select outro audio")?.path ?? newShowForm.outroPath },
                onClearAsset: { kind in
                    switch kind {
                    case .intro: newShowForm.introPath = nil
                    case .outro: newShowForm.outroPath = nil
                    }
                },
                onDropAsset: { kind, url in
                    switch kind {
                    case .intro: newShowForm.introPath = url.path
                    case .outro: newShowForm.outroPath = url.path
                    }
                },
                onCreate: { _ in createShow() }
            )
        }
    }

    // MARK: - Sheet presentation

    private func presentNewEpisode() {
        newEpisodeForm = NewEpisodeForm()
        newEpisodeError = nil
        isCreatingEpisode = false
        store.refreshAvailableShows()
        showingNewEpisode = true
    }

    private func presentNewShow() {
        newShowForm = NewShowForm()
        newShowError = nil
        isCreatingShow = false
        showingNewShow = true
    }

    // MARK: - Pickers

    private func pickShowForEpisode() {
        guard let url = store.pickExistingShowBundle() else { return }
        attachShow(path: url.path, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Attach a Show to the new-Episode form — shared by the library list,
    /// drag-and-drop, and the panel fallback.
    private func attachShow(path: String, name: String) {
        newEpisodeForm.attachedShowPath = path
        newEpisodeForm.attachedShowName = name
    }

    private func pickSpeakerAudio(speakerID: UUID) {
        guard let url = store.pickAudioFile(prompt: "Select speaker audio or video", allowVideo: true) else { return }
        if let idx = newEpisodeForm.speakers.firstIndex(where: { $0.id == speakerID }) {
            newEpisodeForm.speakers[idx].audioPath = url.path
        }
    }

    // MARK: - Create actions

    private func createEpisode() {
        newEpisodeError = nil
        isCreatingEpisode = true
        let form = newEpisodeForm
        Task { @MainActor in
            let error = await store.createEpisode(form: form)
            isCreatingEpisode = false
            if let error {
                newEpisodeError = error
            } else {
                showingNewEpisode = false
            }
        }
    }

    private func createShow() {
        newShowError = nil
        isCreatingShow = true
        let form = newShowForm
        Task { @MainActor in
            let error = await store.createShow(form: form)
            isCreatingShow = false
            if let error {
                newShowError = error
            } else {
                showingNewShow = false
            }
        }
    }
}

/// The editing operations reachable from the episode action bar. Each one
/// replaces the main window content with its own full-window pane (no modal
/// sheet) — see `EpisodeView.operationPane`.
enum EpisodeOperation: String, Identifiable, CaseIterable {
    case slice, polish, chapters, mix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slice: return "Slice"
        case .polish: return "Polish"
        case .chapters: return "Chapters"
        case .mix: return "Mix"
        }
    }

    var icon: String {
        switch self {
        case .slice: return "scissors"
        case .polish: return "wand.and.stars"
        case .chapters: return "list.bullet.rectangle"
        case .mix: return "square.stack.3d.down.forward"
        }
    }
}

struct EpisodeView: View {
    let bundle: EpisodeBundle
    @Environment(EpisodeStore.self) private var store
    /// Which operation pane currently occupies the main window. `nil` ⇒ the
    /// normal episode overview (tracks + activity + action bar).
    @State private var activeOperation: EpisodeOperation?

    var body: some View {
        ZStack {
            if let activeOperation {
                operationPane(activeOperation)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else {
                episodeOverview
                    .transition(.opacity)
            }
        }
        .background(MaycastPalette.bg1)
    }

    private var episodeOverview: some View {
        VStack(spacing: 0) {
            headerBand
            if bundle.episode.tracks.isEmpty {
                emptyTracks
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TRACKS")
                                .font(MaycastFont.body(10.5, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(MaycastPalette.fg3)
                            ForEach(bundle.episode.tracks) { track in
                                TrackRow(track: track)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("ACTIVITY")
                                .font(MaycastFont.body(10.5, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(MaycastPalette.fg3)
                            RecentActivityPanel(bundle: bundle)
                        }
                        .frame(width: 360, alignment: .topLeading)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 22)
                }
                actionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Operation panes (in-place, replacing the overview)

    private func open(_ operation: EpisodeOperation) {
        withAnimation(.easeInOut(duration: 0.22)) { activeOperation = operation }
    }

    private func closeOperation() {
        withAnimation(.easeInOut(duration: 0.22)) { activeOperation = nil }
    }

    /// Render the chosen operation as a full-window pane: a shared back bar on
    /// top, the operation's own view filling the rest. `onDone` reloads the
    /// bundle so the overview reflects the new generation when we return.
    @ViewBuilder
    private func operationPane(_ operation: EpisodeOperation) -> some View {
        VStack(spacing: 0) {
            OperationBackBar(episodeID: bundle.episode.id, operation: operation, onBack: closeOperation)
            Group {
                switch operation {
                case .slice:
                    EditorSheet(bundle: bundle, onDone: reload, onClose: closeOperation)
                case .polish:
                    PolishSheet(bundle: bundle, onDone: reload, onClose: closeOperation)
                case .chapters:
                    ChapterSheet(bundle: bundle, onDone: reload, onClose: closeOperation)
                case .mix:
                    MixSheet(bundle: bundle, onDone: reload, onClose: closeOperation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() { store.open(at: bundle.url) }

    private var headerBand: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(bundle.episode.id)
                    .font(MaycastFont.display(28, weight: .heavy))
                    .foregroundStyle(MaycastPalette.ink900)
                if let show = bundle.episode.show {
                    MaycastChip(show, tone: .mint) {
                        Image(systemName: "shippingbox").font(.system(size: 10))
                    }
                }
                MaycastChip("\(bundle.episode.tracks.count) tracks", tone: .neutral) {
                    Image(systemName: "rectangle.stack").font(.system(size: 10))
                }
                Spacer()
                Text(bundle.episode.uuid.uuidString)
                    .font(MaycastFont.mono(10.5))
                    .tracking(1)
                    .foregroundStyle(MaycastPalette.fg3)
            }
            Text(bundle.url.path)
                .font(MaycastFont.mono(11))
                .foregroundStyle(MaycastPalette.fg3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [MaycastPalette.mint50, Color.white],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
        }
    }

    private var emptyTracks: some View {
        VStack(spacing: 12) {
            Spacer()
            MaycastIconTile(systemName: "waveform", size: 56, iconSize: 26, tone: .mint)
            Text("No tracks yet")
                .font(MaycastFont.display(20, weight: .bold))
                .foregroundStyle(MaycastPalette.fg1)
            Text("Run `maycast import` to add audio sources.")
                .font(MaycastFont.body(13))
                .foregroundStyle(MaycastPalette.fg2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { store.undo() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                    Text(undoButtonLabel)
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle())
            .disabled(!store.canUndo)

            if store.canRedo {
                Button { store.redo() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.forward").font(.system(size: 12))
                        Text("Redo")
                    }
                }
                .buttonStyle(MaycastSecondaryButtonStyle())
            }

            Rectangle().fill(MaycastPalette.border1).frame(width: 1, height: 24)

            Button { open(.slice) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scissors").font(.system(size: 12))
                    Text("Slice")
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle())

            Button { open(.polish) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 12))
                    Text("Polish")
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle())

            Button { open(.chapters) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 12))
                    Text("Chapters")
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle())

            Button { open(.mix) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.down.forward").font(.system(size: 12))
                    Text("Mix")
                }
            }
            .buttonStyle(MaycastPrimaryButtonStyle(glow: true))

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.6), Color(hex: 0xF6F9F8).opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
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

// MARK: - Operation back bar

/// Top bar shown above an in-place operation pane. The back button returns to
/// the episode overview; the right side labels which operation is active.
struct OperationBackBar: View {
    let episodeID: String
    let operation: EpisodeOperation
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { onBack() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text(episodeID)
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle())

            Rectangle().fill(MaycastPalette.border1).frame(width: 1, height: 24)

            Image(systemName: operation.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg2)
            Text(operation.title)
                .font(MaycastFont.display(16, weight: .bold))
                .foregroundStyle(MaycastPalette.fg1)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [MaycastPalette.mint50, Color.white],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(MaycastPalette.fg2)
                Text("Recent activity")
                    .font(MaycastFont.body(13, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg1)
                if totalBatchCount > 0 {
                    Text("(\(totalBatchCount) total)")
                        .font(MaycastFont.body(11))
                        .foregroundStyle(MaycastPalette.fg3)
                }
                Spacer()
                Button("Show all…") { store.isShowingHistory = true }
                    .buttonStyle(MaycastGhostButtonStyle(size: .small))
                    .disabled(totalBatchCount == 0 && undoneBatchCount == 0)
            }
            if appliedBatches.isEmpty && undoneBatchCount == 0 {
                Text("No operations recorded yet.")
                    .font(MaycastFont.body(12))
                    .foregroundStyle(MaycastPalette.fg3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 4) {
                    ForEach(appliedBatches.prefix(maxRows).map { $0 }) { batch in
                        CompactBatchRow(batch: batch, style: .applied)
                    }
                    if undoneBatchCount > 0, appliedBatches.count < maxRows,
                       let nextRedo = undoneBatchesReversed.first {
                        CompactBatchRow(batch: nextRedo, style: .undone)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MaycastPalette.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
                )
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
        HStack(spacing: 10) {
            MaycastIconTile(systemName: icon, size: 26, iconSize: 12, tone: tone, cornerRadius: 7)
            Text(batch.kind.capitalized)
                .font(MaycastFont.body(12.5, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
            Text(batch.trackSummary)
                .font(MaycastFont.mono(11))
                .foregroundStyle(MaycastPalette.fg3)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            if style == .undone {
                Text("(undone)")
                    .font(MaycastFont.body(10))
                    .foregroundStyle(MaycastPalette.fg4)
            }
            Text(batch.timestamp, style: .relative)
                .font(MaycastFont.mono(11))
                .foregroundStyle(MaycastPalette.fg3)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
        )
        .opacity(style == .undone ? 0.55 : 1.0)
    }

    private var icon: String {
        switch batch.kind {
        case "slice": return "scissors"
        case "polish": return "wand.and.stars"
        case "mix": return "rectangle.stack"
        default: return "circle.fill"
        }
    }

    private var tone: MaycastChip<EmptyView>.Tone {
        switch batch.kind {
        case "slice": return .sky
        case "polish": return .mint
        case "mix": return .sun
        default: return .neutral
        }
    }
}

struct TrackRow: View {
    let track: Track

    var body: some View {
        MaycastCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
            HStack(alignment: .top, spacing: 14) {
                MaycastIconTile(systemName: "waveform", size: 44, iconSize: 20, tone: .mint)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(track.id)
                            .font(MaycastFont.mono(13.5, weight: .bold))
                            .foregroundStyle(MaycastPalette.fg1)
                        MaycastChip("\(track.history.count) gen\(track.history.count == 1 ? "" : "s")", tone: .neutral)
                    }
                    label("source",  track.source)
                    label("current", track.current)
                }
                Spacer(minLength: 8)
                MaycastDecorativeWaveform(seed: track.id.hashValue & 0xFF, color: MaycastPalette.mint400, style: .blocks, intensity: 0.7)
                    .frame(width: 200, height: 36)
            }
        }
    }

    private func label(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(key):")
                .font(MaycastFont.mono(10.5, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg4)
            Text(value)
                .font(MaycastFont.mono(11))
                .foregroundStyle(MaycastPalette.fg2)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Full-window "failed to open" surface — warm amber gradient, big icon, and
/// the failure detail in a soft mono block. Matches docs/design/misc.jsx.
struct ErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Circle()
                .fill(LinearGradient(
                    colors: [Color(hex: 0xFFF0D0), Color(hex: 0xFFD994)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xC4760A))
                )
                .shadow(color: MaycastPalette.warning.opacity(0.25), radius: 16, x: 0, y: 4)
            Text("Failed to open Episode")
                .font(MaycastFont.display(22, weight: .bold))
                .foregroundStyle(MaycastPalette.fg1)
            Text("The bundle could not be opened. The detail below may help diagnose what went wrong.")
                .font(MaycastFont.body(13.5))
                .foregroundStyle(MaycastPalette.fg2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text(message)
                .font(MaycastFont.mono(11.5))
                .foregroundStyle(MaycastPalette.fg2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: 520, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(MaycastPalette.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
                )
            HStack(spacing: 10) {
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(MaycastPrimaryButtonStyle(glow: true))
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0xFFF7E6), location: 0),
                    .init(color: Color.white, location: 0.5),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
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

#Preview("Empty State (Home / no recents)") {
    ContentView()
        .environment(EpisodeStore())
}

#Preview("Home with recents") {
    ContentView().environment({
        let store = EpisodeStore()
        store.recents = [
            RecentEpisode(
                displayName: "ep01",
                absolutePath: "/Users/henteko/Podcasts/my-podcast/ep01.maycast",
                lastOpened: Date().addingTimeInterval(-60 * 30),
                showName: "my-podcast"
            ),
            RecentEpisode(
                displayName: "ep00-pilot",
                absolutePath: "/Users/henteko/Podcasts/my-podcast/ep00-pilot.maycast",
                lastOpened: Date().addingTimeInterval(-60 * 60 * 6),
                showName: "my-podcast"
            ),
        ]
        return store
    }())
}

#Preview("With Tracks") {
    ContentView().environment({
        let store = EpisodeStore()
        store.bundle = .sampleWithTracks
        return store
    }())
}

#Preview("No Tracks") {
    ContentView().environment({
        let store = EpisodeStore()
        store.bundle = .sampleEmpty
        return store
    }())
}

#Preview("Error State") {
    ContentView().environment({
        let store = EpisodeStore()
        store.errorMessage = "Manifest not found at /tmp/missing.maycast/episode.json"
        return store
    }())
}

#Preview("TrackRow") {
    TrackRow(track: .sampleHost)
        .padding()
}

#Preview("Operation back bar") {
    VStack(spacing: 0) {
        ForEach(EpisodeOperation.allCases) { op in
            OperationBackBar(episodeID: "ep01", operation: op, onBack: {})
        }
    }
}
#endif
