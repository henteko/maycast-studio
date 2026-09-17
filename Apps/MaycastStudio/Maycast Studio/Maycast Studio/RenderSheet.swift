import SwiftUI
import AppKit
import MaycastCore

/// Value-type state for the Render pane, so `RenderView` is a pure function of
/// it and can be previewed in every state.
enum RenderState: Equatable {
    case idle
    case rendering(label: String, fraction: Double)
    case done(artifacts: [VideoRenderer.Artifact])
    case failed(message: String)
}

/// One speaker that will be rendered to mp4: the video source it was
/// imported from and the length of the edited output.
struct RenderSpeaker: Identifiable, Equatable {
    let id: String
    let sourcePath: String
    let duration: TimeInterval?

    init(track: Track) {
        id = track.id
        sourcePath = track.videoSource ?? track.source
        duration = track.videoEdit?.totalDuration
    }

    init(id: String, sourcePath: String, duration: TimeInterval?) {
        self.id = id
        self.sourcePath = sourcePath
        self.duration = duration
    }
}

// MARK: - Container

/// Runs `VideoRenderer` (per-speaker mp4) off the main actor and drives
/// `RenderView`. Rendered inline in the main window inside its own
/// `MaycastOperationShell` (no legacy back bar).
struct RenderSheet: View {
    let bundle: EpisodeBundle
    /// Return to the episode overview (the shell's back button).
    let onClose: () -> Void

    @State private var state: RenderState = .idle
    @State private var progress = ProgressRelay()
    @State private var task: Task<Void, Never>?

    var body: some View {
        RenderView(
            episodeID: bundle.episode.id,
            speakers: bundle.episode.tracks.filter(\.hasVideo).map(RenderSpeaker.init(track:)),
            state: state,
            onRender: { runRender() },
            onCancel: { cancelRender() },
            onReveal: { reveal($0) },
            onBack: onClose
        )
        .onDisappear { task?.cancel() }
        .onChange(of: progress.fraction) { _, f in
            if case .rendering = state { state = .rendering(label: progress.label, fraction: f) }
        }
    }

    private func runRender() {
        guard bundle.episode.tracks.contains(where: { $0.hasVideo }) else {
            state = .failed(message: "This episode has no video tracks to render.")
            return
        }
        task?.cancel()
        progress.reset(label: "Starting…")
        state = .rendering(label: "Starting…", fraction: 0)
        let bundleURL = bundle.url
        let relay = progress
        task = Task {
            do {
                let artifacts = try await Task.detached(priority: .userInitiated) {
                    try OperationsService().runRender(bundleURL: bundleURL, onProgress: { label, f in
                        Task { @MainActor in relay.update(f, label: label) }
                    })
                }.value
                if Task.isCancelled { return }
                state = .done(artifacts: artifacts)
            } catch is CancellationError {
                state = .failed(message: "Cancelled.")
            } catch {
                if Task.isCancelled { return }
                state = .failed(message: String(describing: error))
            }
        }
    }

    private func cancelRender() {
        task?.cancel()
        task = nil
        state = .failed(message: "Cancelled.")
    }

    private func reveal(_ artifact: VideoRenderer.Artifact) {
        let url = bundle.url.appendingPathComponent(artifact.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - View

/// Pure, previewable Render surface.
///
/// Rendered inside `MaycastOperationShell`: the shell owns the back button,
/// title, status banner and the single primary action. This view supplies
/// the plan (which speakers become mp4s), the results, and the state-driven
/// footer pieces.
struct RenderView: View {
    let episodeID: String
    let speakers: [RenderSpeaker]
    let state: RenderState
    var onRender: () -> Void = {}
    var onCancel: () -> Void = {}
    var onReveal: (VideoRenderer.Artifact) -> Void = { _ in }
    /// Return to the episode overview (the shell's back button).
    var onBack: () -> Void = {}

    var body: some View {
        MaycastOperationShell(
            episodeID: episodeID,
            icon: "film",
            tone: .sky,
            title: "Render",
            subtitle: "Export one mp4 per speaker, cut to the edited audio",
            onBack: onBack,
            accessory: { headerChips },
            content: { content },
            status: { statusSection },
            leading: { EmptyView() },
            trailing: { trailingActions }
        )
    }

    // MARK: header chips

    private var headerChips: some View {
        MaycastChip("\(speakers.count) speaker\(speakers.count == 1 ? "" : "s")", tone: .neutral) {
            Image(systemName: "person.wave.2").font(.system(size: 10))
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if speakers.isEmpty {
            VStack {
                Spacer()
                MaycastEmptyState(
                    icon: "film",
                    tone: .sky,
                    title: "Nothing to render",
                    message: "No speaker in this episode was imported from a video. Render writes one mp4 per video speaker; the audio mp3 comes from Mix."
                )
                .frame(maxWidth: 420)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    planSection
                    if case .done(let artifacts) = state, !artifacts.isEmpty {
                        resultsSection(artifacts)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: plan

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Plan", trailing: "one mp4 per speaker · chapters embedded · no intro / outro")
            MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                VStack(spacing: 8) {
                    ForEach(speakers) { speaker in
                        MaycastTrackRow(
                            id: speaker.id,
                            path: speaker.sourcePath,
                            duration: speaker.duration,
                            tone: .sky,
                            icon: "film"
                        )
                    }
                }
            }
        }
    }

    // MARK: results

    private func resultsSection(_ artifacts: [VideoRenderer.Artifact]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Rendered", trailing: "written into the episode bundle")
            MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                VStack(spacing: 8) {
                    ForEach(artifacts, id: \.relativePath) { artifact in
                        HStack(spacing: 10) {
                            MaycastTrackRow(
                                id: artifact.trackID,
                                path: artifact.relativePath,
                                tone: .success,
                                icon: "checkmark"
                            )
                            Button("Show in Finder") { onReveal(artifact) }
                                .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                        }
                    }
                }
            }
        }
    }

    // MARK: status (footer)

    @ViewBuilder
    private var statusSection: some View {
        switch state {
        case .idle:
            MaycastStatusBanner(
                tone: .idle, icon: "circle.dashed",
                title: "Ready to render",
                detail: speakers.isEmpty
                    ? nil
                    : "\(speakers.count) video\(speakers.count == 1 ? "" : "s") will be written to exports/ (\(speakers.map { "\($0.id).mp4" }.joined(separator: ", ")))."
            )
        case .rendering(let label, let fraction):
            VStack(spacing: 8) {
                MaycastStatusBanner(
                    tone: .progress,
                    title: "Rendering…",
                    detail: label.isEmpty ? nil : label,
                    spinning: true
                )
                MaycastProgressRows(rows: [MaycastProgressRow(id: "all", value: fraction)])
            }
        case .done(let artifacts):
            MaycastStatusBanner(
                tone: .success, icon: "checkmark.seal.fill",
                title: "Render complete (\(artifacts.count) video\(artifacts.count == 1 ? "" : "s"))",
                detail: "Each mp4 is cut to the edited audio and carries the episode chapters."
            )
        case .failed(let message):
            MaycastStatusBanner(
                tone: .danger, icon: "exclamationmark.triangle.fill",
                title: "Render failed",
                detail: message
            )
        }
    }

    // MARK: footer actions

    @ViewBuilder
    private var trailingActions: some View {
        if isRendering {
            Button("Cancel") { onCancel() }
                .buttonStyle(MaycastDestructiveButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        Button(action: onRender) {
            HStack(spacing: 6) {
                if !disableRender {
                    Image(systemName: "film").font(.system(size: 12))
                }
                Text(renderLabel)
            }
        }
        .buttonStyle(MaycastPrimaryButtonStyle(glow: !disableRender))
        .keyboardShortcut(.defaultAction)
        .disabled(disableRender)
    }

    private var renderLabel: String {
        switch state {
        case .rendering: return "Rendering…"
        case .done: return "Render again"
        default: return "Render"
        }
    }

    private var disableRender: Bool { isRendering || speakers.isEmpty }
    private var isRendering: Bool { if case .rendering = state { return true } else { return false } }
}

// MARK: - Previews

#if DEBUG
private let renderSampleSpeakers: [RenderSpeaker] = [
    RenderSpeaker(track: .sampleVideoHost),
    RenderSpeaker(id: "guest", sourcePath: "sources/guest.mov", duration: 118.5),
]

private struct RenderPreviewHost: View {
    var state: RenderState
    var speakers: [RenderSpeaker] = renderSampleSpeakers
    var size: CGSize = CGSize(width: 1100, height: 760)

    var body: some View {
        RenderView(
            episodeID: EpisodeBundle.sampleWithTracks.episode.id,
            speakers: speakers,
            state: state
        )
        .frame(width: size.width, height: size.height)
    }
}

#Preview("Idle") {
    RenderPreviewHost(state: .idle)
}

#Preview("Rendering") {
    RenderPreviewHost(state: .rendering(label: "Rendering host.mp4", fraction: 0.42))
}

#Preview("Completed") {
    RenderPreviewHost(state: .done(artifacts: [
        .init(trackID: "host", relativePath: "exports/host.mp4"),
        .init(trackID: "guest", relativePath: "exports/guest.mp4"),
    ]))
}

#Preview("Failed") {
    RenderPreviewHost(state: .failed(message: "Video render mismatch: got 12.00s, expected 18.00s."))
}

#Preview("Empty — no video speakers") {
    RenderPreviewHost(state: .idle, speakers: [])
}

#Preview("Compact window") {
    RenderPreviewHost(state: .idle, size: CGSize(width: 720, height: 520))
}
#endif
