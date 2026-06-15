import SwiftUI
import AppKit
import MaycastCore

/// Value-type state for the Export pane, so `ExportView` is a pure function of
/// it and can be previewed in every state.
enum ExportState: Equatable {
    case idle
    case exporting
    case done(artifacts: [EpisodeExporter.Artifact])
    case failed(message: String)
}

// MARK: - Container

/// Runs `EpisodeExporter` (mp3 mix + per-speaker mp4) off the main actor and
/// drives `ExportView`. Rendered inline in the main window (the shared back bar
/// lives above it).
struct ExportSheet: View {
    let bundle: EpisodeBundle
    let onClose: () -> Void

    @State private var state: ExportState = .idle
    @State private var task: Task<Void, Never>?

    private let operations = OperationsService()

    var body: some View {
        ExportView(
            episodeID: bundle.episode.id,
            videoTrackIDs: bundle.episode.tracks.filter(\.hasVideo).map(\.id),
            state: state,
            onExport: { runExport() },
            onReveal: { reveal($0) },
            onClose: onClose
        )
        .onDisappear { task?.cancel() }
    }

    private func runExport() {
        guard !bundle.episode.tracks.isEmpty else {
            state = .failed(message: "Episode has no tracks to export.")
            return
        }
        state = .exporting
        let bundleURL = bundle.url
        task = Task {
            do {
                let artifacts = try await Task.detached(priority: .userInitiated) {
                    try OperationsService().runExport(bundleURL: bundleURL)
                }.value
                state = .done(artifacts: artifacts)
            } catch {
                state = .failed(message: String(describing: error))
            }
        }
    }

    private func reveal(_ artifact: EpisodeExporter.Artifact) {
        let url = bundle.url.appendingPathComponent(artifact.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - View

/// Pure, previewable Export surface.
struct ExportView: View {
    let episodeID: String
    let videoTrackIDs: [String]
    let state: ExportState
    var onExport: () -> Void
    var onReveal: (EpisodeExporter.Artifact) -> Void
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
            MaycastIconTile(systemName: "square.and.arrow.up", tone: .mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export")
                    .font(MaycastFont.display(19, weight: .bold))
                    .foregroundStyle(MaycastPalette.fg1)
                Text("Produces the final mp3 (full mix with chapters) and one mp4 per speaker that has video.")
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
            sectionLabel("Will produce", icon: "doc.on.doc")
            VStack(spacing: 8) {
                planRow(icon: "music.note", title: "\(episodeID).mp3", detail: "Full mix · intro / outro · chapters")
                if videoTrackIDs.isEmpty {
                    Text("No video tracks — only the mp3 mix is produced.")
                        .font(MaycastFont.body(11))
                        .foregroundStyle(MaycastPalette.fg4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(videoTrackIDs, id: \.self) { id in
                        planRow(icon: "film", title: "\(id).mp4", detail: "\(id) video + audio · chapters · no intro / outro")
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5))
        }
    }

    private func planRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            MaycastIconTile(systemName: icon, size: 28, iconSize: 13, tone: .mint, cornerRadius: 7)
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

    private func results(_ artifacts: [EpisodeExporter.Artifact]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Exported", icon: "checkmark.seal.fill")
            VStack(spacing: 6) {
                ForEach(artifacts, id: \.relativePath) { artifact in
                    HStack(spacing: 10) {
                        Image(systemName: artifact.kind == .mp3 ? "music.note" : "film")
                            .foregroundStyle(MaycastPalette.mint600)
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
            if case .exporting = state {
                ProgressView().controlSize(.small)
                Text("Exporting…").font(MaycastFont.body(12)).foregroundStyle(MaycastPalette.fg2)
            }
            Spacer()
            Button(isDone ? "Export again" : "Export", action: onExport)
                .buttonStyle(MaycastPrimaryButtonStyle(glow: !isExporting))
                .disabled(isExporting)
        }
    }

    private var isExporting: Bool { if case .exporting = state { return true } else { return false } }
    private var isDone: Bool { if case .done = state { return true } else { return false } }
}

// MARK: - Previews

#if DEBUG
#Preview("Export — idle (video episode)") {
    ExportView(
        episodeID: "ep01",
        videoTrackIDs: ["host", "guest"],
        state: .idle,
        onExport: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Export — audio only") {
    ExportView(
        episodeID: "ep01",
        videoTrackIDs: [],
        state: .idle,
        onExport: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Export — exporting") {
    ExportView(
        episodeID: "ep01",
        videoTrackIDs: ["host", "guest"],
        state: .exporting,
        onExport: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Export — done") {
    ExportView(
        episodeID: "ep01",
        videoTrackIDs: ["host", "guest"],
        state: .done(artifacts: [
            .init(trackID: nil, relativePath: "exports/ep01.mp3", kind: .mp3),
            .init(trackID: "host", relativePath: "exports/host.mp4", kind: .mp4),
            .init(trackID: "guest", relativePath: "exports/guest.mp4", kind: .mp4),
        ]),
        onExport: {}, onReveal: { _ in }, onClose: {}
    )
}

#Preview("Export — failed") {
    ExportView(
        episodeID: "ep01",
        videoTrackIDs: ["host"],
        state: .failed(message: "ffmpeg not found. Install it with `brew install ffmpeg`."),
        onExport: {}, onReveal: { _ in }, onClose: {}
    )
}
#endif
