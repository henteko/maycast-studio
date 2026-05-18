import SwiftUI
import MaycastCore

/// Summary of a track for display in the Mix panel.
struct MixTrackSummary: Identifiable, Sendable {
    let id: String
    let currentPath: String
    let duration: TimeInterval
}

enum MixState: Sendable, Equatable {
    case idle
    case mixing(progress: Double)            // 0.0..1.0
    case completed(path: String, duration: TimeInterval, byteSize: Int)
    case failed(message: String)
}

/// Mix panel UI — Phase 1.3 mockup. Real wiring to the Mix XPC service
/// happens in Phase 1.5.
struct MixView: View {
    let tracks: [MixTrackSummary]
    @Binding var outputPath: String
    @Binding var state: MixState
    var onMix: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil

    private var totalDuration: TimeInterval {
        tracks.map(\.duration).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            tracksSection
            Divider()
            outputSection
            Divider()
            statusSection
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 460)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mix").font(.title2.bold())
            Spacer()
            Label("\(tracks.count) track\(tracks.count == 1 ? "" : "s")",
                  systemImage: "rectangle.stack")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tracks to mix").font(.headline)
            ForEach(tracks) { track in
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.id).font(.body.weight(.medium))
                        Text(track.currentPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(formattedSeconds(track.duration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Text("Output duration").foregroundStyle(.secondary)
                Spacer()
                Text(formattedSeconds(totalDuration))
                    .font(.callout.monospacedDigit())
            }
            HStack {
                Text("Output format").foregroundStyle(.secondary)
                Spacer()
                Text("16-bit PCM WAV · stereo")
                    .font(.callout)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output path").font(.headline)
            TextField("exports/episode.wav", text: $outputPath)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch state {
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Text("Ready to mix").foregroundStyle(.secondary)
            }
        case .mixing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Mixing…")
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
        case .completed(let path, let duration, let byteSize):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Mix complete").font(.headline)
                }
                HStack(spacing: 12) {
                    Text(path).font(.caption.monospaced())
                    Spacer()
                    Text("\(formattedSeconds(duration)) · \(formattedSize(byteSize))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Mix failed").font(.headline)
                }
                Text(message)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if case .completed = state {
                Button("Reveal in Finder") { onReveal?() }
            }
            Button(action: { onMix?() }) {
                switch state {
                case .mixing: Text("Mixing…")
                case .completed: Text("Mix again")
                default: Text("Mix")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(disableMixButton)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var disableMixButton: Bool {
        if case .mixing = state { return true }
        return tracks.isEmpty || outputPath.isEmpty
    }

    // MARK: - Formatting

    private func formattedSeconds(_ value: TimeInterval) -> String {
        if value < 60 { return String(format: "%.2fs", value) }
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, seconds)
    }

    private func formattedSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(bytes / 1024) KB"
    }
}

// MARK: - Previews

#if DEBUG
private let mixSampleTracks: [MixTrackSummary] = [
    MixTrackSummary(id: "host",  currentPath: "intermediate/host/004_slice.wav",  duration: 12.5),
    MixTrackSummary(id: "guest", currentPath: "intermediate/guest/002_slice.wav", duration: 10.2),
]

private struct MixPreviewHost: View {
    @State var outputPath: String
    @State var state: MixState
    var body: some View {
        MixView(
            tracks: mixSampleTracks,
            outputPath: $outputPath,
            state: $state
        )
    }
}
#endif

#Preview("Idle") {
    MixPreviewHost(outputPath: "exports/ep01.wav", state: .idle)
}

#Preview("Mixing (progress 0.45)") {
    MixPreviewHost(outputPath: "exports/ep01.wav", state: .mixing(progress: 0.45))
}

#Preview("Completed") {
    MixPreviewHost(
        outputPath: "exports/ep01.wav",
        state: .completed(path: "exports/ep01.wav", duration: 12.5, byteSize: 2_412_032)
    )
}

#Preview("Failed") {
    MixPreviewHost(
        outputPath: "exports/ep01.wav",
        state: .failed(message: "Service failed: no track audio found to mix")
    )
}

#Preview("Empty (no tracks)") {
    MixView(
        tracks: [],
        outputPath: .constant("exports/ep01.wav"),
        state: .constant(.idle)
    )
}
