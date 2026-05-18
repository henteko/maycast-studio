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

/// Settings for the Intro/Outro overlap stage of the final mix.
struct MixOverlaySettings: Equatable, Sendable {
    var introPath: String?      // relative to the bundle, may be nil
    var outroPath: String?
    var introOffsetSec: Double
    var outroOffsetSec: Double
    var duckingGainDB: Double
    var duckingFadeSec: Double

    static let defaults = MixOverlaySettings(
        introPath: nil,
        outroPath: nil,
        introOffsetSec: 2.0,
        outroOffsetSec: 5.0,
        duckingGainDB: -12,
        duckingFadeSec: 0.5
    )
}

/// Mix panel UI. Phase 3.4 brings intro / outro overlap with linear ducking
/// during the overlap region.
/// State of a Mix overlap preview (audio playback of the intro / outro
/// transition region without rendering the full episode).
enum MixPreviewState: Sendable, Equatable {
    case idle
    case rendering(kind: MixOverlapKind)
    case playing(kind: MixOverlapKind)
    case failed(message: String)
}

struct MixView: View {
    let tracks: [MixTrackSummary]
    @Binding var outputPath: String
    @Binding var state: MixState
    @Binding var overlay: MixOverlaySettings
    /// Duration of the currently-attached intro / outro asset (read once
    /// when the sheet loads). Used as the upper bound of the overlap slider
    /// so the user can't request an offset longer than the file itself.
    var introDurationSec: Double = 0
    var outroDurationSec: Double = 0
    var preview: MixPreviewState = .idle
    var onMix: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil
    var onPreview: ((MixOverlapKind) -> Void)? = nil
    var onStopPreview: (() -> Void)? = nil

    private var totalDuration: TimeInterval {
        tracks.map(\.duration).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            tracksSection
            Divider()
            overlaySection
            Divider()
            outputSection
            Divider()
            statusSection
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 600)
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

    private var overlaySection: some View {
        let hasIntroOrOutro = overlay.introPath != nil || overlay.outroPath != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Intro / Outro overlap", systemImage: "music.note")
                    .font(.headline)
                Spacer()
                if !hasIntroOrOutro {
                    Text("Inherits from Show on init")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            assetRow(label: "Intro", path: overlay.introPath, durationSec: introDurationSec)
            assetRow(label: "Outro", path: overlay.outroPath, durationSec: outroDurationSec)

            if hasIntroOrOutro {
                Divider().padding(.vertical, 2)
                slider(label: "Intro overlap",
                       value: $overlay.introOffsetSec,
                       range: 0 ... max(introDurationSec, 0.5),
                       step: 0.5,
                       suffix: "s",
                       disabled: overlay.introPath == nil || introDurationSec <= 0)
                slider(label: "Outro overlap",
                       value: $overlay.outroOffsetSec,
                       range: 0 ... max(outroDurationSec, 0.5),
                       step: 0.5,
                       suffix: "s",
                       disabled: overlay.outroPath == nil || outroDurationSec <= 0)
                slider(label: "Ducking gain",
                       value: $overlay.duckingGainDB,
                       range: -24 ... 0,
                       step: 1,
                       suffix: "dB")
                slider(label: "Ducking fade",
                       value: $overlay.duckingFadeSec,
                       range: 0 ... 2,
                       step: 0.1,
                       suffix: "s")

                Divider().padding(.vertical, 2)
                previewRow
            }
        }
    }

    private var previewRow: some View {
        HStack(spacing: 8) {
            previewButton(label: "Preview intro transition",
                          icon: "play.circle",
                          kind: .intro,
                          disabled: overlay.introPath == nil)
            previewButton(label: "Preview outro transition",
                          icon: "play.circle",
                          kind: .outro,
                          disabled: overlay.outroPath == nil)
            Spacer()
            if case .playing = preview {
                Button { onStopPreview?() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else if case .rendering = preview {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Rendering…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .leading) {
            if case .failed(let msg) = preview {
                Text(msg)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .padding(.top, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func previewButton(label: String, icon: String, kind: MixOverlapKind, disabled: Bool) -> some View {
        let activeForThis: Bool = {
            switch preview {
            case .rendering(let k), .playing(let k): return k == kind
            default: return false
            }
        }()
        Button { onPreview?(kind) } label: {
            Label(label, systemImage: activeForThis ? "waveform" : icon)
        }
        .buttonStyle(.bordered)
        .disabled(disabled || preview != .idle && !activeForThis)
        .symbolEffect(.pulse, isActive: activeForThis && {
            if case .playing = preview { return true } else { return false }
        }())
    }

    private func assetRow(label: String, path: String?, durationSec: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: path != nil ? "checkmark.seal.fill" : "circle.dashed")
                .foregroundStyle(path != nil ? .green : .secondary)
            Text(label)
                .frame(width: 60, alignment: .leading)
                .font(.callout.weight(.medium))
            Text(path ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(path != nil ? .secondary : .tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if path != nil, durationSec > 0 {
                Text(String(format: "%.1fs", durationSec))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func slider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double.Stride,
        suffix: String,
        disabled: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(disabled ? .secondary : .primary)
            Slider(value: value, in: range, step: step)
                .disabled(disabled)
            Text(String(format: "%.1f%@", value.wrappedValue, suffix))
                .frame(width: 70, alignment: .trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(disabled ? .secondary : .primary)
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
    @State var overlay: MixOverlaySettings = .defaults
    var preview: MixPreviewState = .idle
    var body: some View {
        MixView(
            tracks: mixSampleTracks,
            outputPath: $outputPath,
            state: $state,
            overlay: $overlay,
            preview: preview
        )
    }
}
#endif

#Preview("Idle (no intro / outro)") {
    MixPreviewHost(outputPath: "exports/ep01.wav", state: .idle)
}

#Preview("Idle (with intro + outro)") {
    MixPreviewHost(
        outputPath: "exports/ep01.wav",
        state: .idle,
        overlay: MixOverlaySettings(
            introPath: "assets/intro.wav",
            outroPath: "assets/outro.wav",
            introOffsetSec: 2.0,
            outroOffsetSec: 5.0,
            duckingGainDB: -12,
            duckingFadeSec: 0.5
        )
    )
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
        state: .constant(.idle),
        overlay: .constant(.defaults)
    )
}

#Preview("Preview rendering") {
    MixPreviewHost(
        outputPath: "exports/ep01.wav",
        state: .idle,
        overlay: MixOverlaySettings(
            introPath: "assets/intro.wav",
            outroPath: "assets/outro.wav",
            introOffsetSec: 2.0,
            outroOffsetSec: 5.0,
            duckingGainDB: -12,
            duckingFadeSec: 0.5
        ),
        preview: .rendering(kind: .intro)
    )
}

#Preview("Preview playing") {
    MixPreviewHost(
        outputPath: "exports/ep01.wav",
        state: .idle,
        overlay: MixOverlaySettings(
            introPath: "assets/intro.wav",
            outroPath: "assets/outro.wav",
            introOffsetSec: 2.0,
            outroOffsetSec: 5.0,
            duckingGainDB: -12,
            duckingFadeSec: 0.5
        ),
        preview: .playing(kind: .outro)
    )
}
