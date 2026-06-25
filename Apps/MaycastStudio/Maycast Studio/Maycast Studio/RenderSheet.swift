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

// MARK: - Container

/// Runs `VideoRenderer` (per-speaker mp4) off the main actor and drives
/// `RenderView`. Rendered inline in the main window (the shared back bar lives
/// above it).
struct RenderSheet: View {
    let bundle: EpisodeBundle
    let onClose: () -> Void

    @State private var state: RenderState = .idle
    @State private var progress = ProgressRelay()
    @State private var task: Task<Void, Never>?

    var body: some View {
        RenderView(
            videoTrackIDs: bundle.episode.tracks.filter(\.hasVideo).map(\.id),
            state: state,
            onRender: { runRender() },
            onReveal: { reveal($0) },
            onClose: onClose
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
                state = .done(artifacts: artifacts)
            } catch {
                state = .failed(message: String(describing: error))
            }
        }
    }

    private func reveal(_ artifact: VideoRenderer.Artifact) {
        let url = bundle.url.appendingPathComponent(artifact.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - View

/// Pure, previewable Render surface.
struct RenderView: View {
    let videoTrackIDs: [String]
    let state: RenderState
    var onRender: () -> Void
    var onReveal: (VideoRenderer.Artifact) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    plan
                    switch state {
                    case .done(let artifacts):
                        results(artifacts)
                    case .failed(let message):
                        errorBox(message)
                    default:
                        EmptyView()
                    }
                }
                .padding(24)
            }
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(MaycastPalette.ink50)
        }
        .background(MaycastPalette.bg1)
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MaycastIconTile(systemName: "film", tone: .mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Render")
                    .font(MaycastFont.display(19, weight: .bold))
                    .foregroundStyle(MaycastPalette.fg1)
                Text("Renders one mp4 per speaker that has video — cut to match the edited audio, with chapters. (Audio mp3 is produced by Mix.)")
                    .font(MaycastFont.body(12.5))
                    .foregroundStyle(MaycastPalette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var plan: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Will produce", icon: "film")
            VStack(spacing: 8) {
                if videoTrackIDs.isEmpty {
                    Text("No video tracks — import a speaker from a video to render mp4.")
                        .font(MaycastFont.body(11))
                        .foregroundStyle(MaycastPalette.fg4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(videoTrackIDs, id: \.self) { id in
                        planRow(title: "\(id).mp4", detail: "\(id) video + audio · chapters · no intro / outro")
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5))
        }
    }

    private func planRow(title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            MaycastIconTile(systemName: "film", size: 28, iconSize: 13, tone: .mint, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MaycastFont.mono(12.5, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg1)
                Text(detail)
                    .font(MaycastFont.body(11))
                    .foregroundStyle(MaycastPalette.fg3)
            }
            Spacer()
        }
    }

    private func results(_ artifacts: [VideoRenderer.Artifact]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Rendered", icon: "checkmark.seal.fill")
            VStack(spacing: 6) {
                ForEach(artifacts, id: \.relativePath) { artifact in
                    HStack(spacing: 10) {
                        Image(systemName: "film").foregroundStyle(MaycastPalette.mint600)
                        Text(artifact.relativePath)
                            .font(MaycastFont.mono(11.5))
                            .foregroundStyle(MaycastPalette.fg1)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") { onReveal(artifact) }
                            .buttonStyle(MaycastGhostButtonStyle(size: .small))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5))
                }
            }
        }
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(MaycastFont.body(12))
                .foregroundStyle(MaycastPalette.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(MaycastPalette.fg2)
            Text(text)
                .font(MaycastFont.body(12.5, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .rendering(let label, let fraction) = state {
                ProgressView(value: fraction).frame(width: 150)
                Text("\(label) \(Int((fraction * 100).rounded()))%")
                    .font(MaycastFont.body(12))
                    .foregroundStyle(MaycastPalette.fg2)
                    .lineLimit(1)
            }
            Spacer()
            Button(isDone ? "Render again" : "Render", action: onRender)
                .buttonStyle(MaycastPrimaryButtonStyle(glow: !isRendering))
                .disabled(isRendering || videoTrackIDs.isEmpty)
        }
    }

    private var isRendering: Bool { if case .rendering = state { return true } else { return false } }
    private var isDone: Bool { if case .done = state { return true } else { return false } }
}

// MARK: - Previews

#if DEBUG
#Preview("Render — idle (video episode)") {
    RenderView(
        videoTrackIDs: ["host", "guest"],
        state: .idle,
        onRender: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Render — no video tracks") {
    RenderView(
        videoTrackIDs: [],
        state: .idle,
        onRender: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Render — rendering") {
    RenderView(
        videoTrackIDs: ["host", "guest"],
        state: .rendering(label: "Rendering host.mp4", fraction: 0.42),
        onRender: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Render — done") {
    RenderView(
        videoTrackIDs: ["host", "guest"],
        state: .done(artifacts: [
            .init(trackID: "host", relativePath: "exports/host.mp4"),
            .init(trackID: "guest", relativePath: "exports/guest.mp4"),
        ]),
        onRender: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Render — failed") {
    RenderView(
        videoTrackIDs: ["host"],
        state: .failed(message: "Video render mismatch: got 12.00s, expected 18.00s."),
        onRender: {}, onReveal: { _ in }, onClose: {}
    )
}
#endif
