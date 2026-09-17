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
    let episodeID: String
    let tracks: [MixTrackSummary]
    @Binding var outputPath: String
    @Binding var state: MixState
    @Binding var overlay: MixOverlaySettings
    /// Duration of the currently-attached intro / outro asset (read once
    /// when the pane loads). Used as the upper bound of the overlap slider
    /// so the user can't request an offset longer than the file itself.
    var introDurationSec: Double = 0
    var outroDurationSec: Double = 0
    var preview: MixPreviewState = .idle
    var onMix: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil
    var onPreview: ((MixOverlapKind) -> Void)? = nil
    var onStopPreview: (() -> Void)? = nil
    /// Return to the episode overview (the shell's back button).
    var onBack: (() -> Void)? = nil

    private var totalDuration: TimeInterval {
        tracks.map(\.duration).max() ?? 0
    }

    private var hasIntroOrOutro: Bool {
        overlay.introPath != nil || overlay.outroPath != nil
    }

    var body: some View {
        MaycastOperationShell(
            episodeID: episodeID,
            icon: "square.stack.3d.down.forward",
            tone: .sun,
            title: "Mix",
            subtitle: "Combine every track with the Show's intro / outro",
            onBack: { onBack?() },
            accessory: { headerChips },
            content: { content },
            status: { statusSection },
            leading: { leadingActions },
            trailing: { trailingActions }
        )
    }

    // MARK: header chips

    private var headerChips: some View {
        HStack(spacing: 6) {
            if !tracks.isEmpty && !hasIntroOrOutro {
                MaycastChip("No intro / outro", tone: .warning) {
                    Image(systemName: "music.note").font(.system(size: 10))
                }
            }
            MaycastChip("\(tracks.count) track\(tracks.count == 1 ? "" : "s")", tone: .neutral) {
                Image(systemName: "rectangle.stack").font(.system(size: 10))
            }
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if tracks.isEmpty {
            VStack {
                Spacer()
                MaycastEmptyState(
                    icon: "waveform",
                    title: "Nothing to mix",
                    message: "This episode has no tracks yet. Import a speaker recording first."
                )
                .frame(maxWidth: 420)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    tracksSection
                    overlaySection
                    outputSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Tracks to mix", trailing: "mixed down to one stereo file")
            MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                VStack(spacing: 8) {
                    ForEach(tracks) { track in
                        MaycastTrackRow(id: track.id, path: track.currentPath, duration: track.duration)
                    }
                    MaycastHairline().padding(.vertical, 2)
                    summaryRow("Output duration", value: MaycastDuration.format(totalDuration))
                    summaryRow("Output format", value: "MP3 (128 kbps) · stereo")
                }
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(MaycastFont.body(12, weight: .medium))
                .foregroundStyle(MaycastPalette.fg2)
            Spacer()
            Text(value)
                .font(MaycastFont.mono(12, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
        }
    }

    // MARK: intro / outro

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Intro / Outro", trailing: hasIntroOrOutro ? "snapshotted from the Show" : "none attached — set them on the Show")
            MaycastCard(padding: EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 8) {
                        assetRow(label: "Intro", path: overlay.introPath, durationSec: introDurationSec)
                        assetRow(label: "Outro", path: overlay.outroPath, durationSec: outroDurationSec)
                    }
                    .padding(.vertical, 4)

                    if hasIntroOrOutro {
                        MaycastHairline().padding(.top, 8)

                        MaycastSettingRow(icon: "arrow.right.to.line", "Intro overlap",
                                          hint: "How long the intro keeps playing under the first speaker",
                                          layout: .stacked,
                                          enabled: overlay.introPath != nil && introDurationSec > 0) {
                            sliderControl($overlay.introOffsetSec, in: 0 ... max(introDurationSec, 0.5), step: 0.5, suffix: "s")
                        }
                        MaycastHairline()
                        MaycastSettingRow(icon: "arrow.left.to.line", "Outro overlap",
                                          hint: "How early the outro starts under the last speaker",
                                          layout: .stacked,
                                          enabled: overlay.outroPath != nil && outroDurationSec > 0) {
                            sliderControl($overlay.outroOffsetSec, in: 0 ... max(outroDurationSec, 0.5), step: 0.5, suffix: "s")
                        }
                        MaycastHairline()
                        MaycastSettingRow(icon: "speaker.wave.1", "Ducking gain",
                                          hint: "Music level while voices overlap it",
                                          layout: .stacked) {
                            sliderControl($overlay.duckingGainDB, in: -24 ... 0, step: 1, suffix: " dB")
                        }
                        MaycastHairline()
                        MaycastSettingRow(icon: "waveform.path", "Ducking fade",
                                          hint: "Ramp in / out of the ducked level",
                                          layout: .stacked) {
                            sliderControl($overlay.duckingFadeSec, in: 0 ... 2, step: 0.1, suffix: "s")
                        }

                        MaycastHairline().padding(.bottom, 10)
                        previewRow
                    }
                }
            }
        }
    }

    private func sliderControl(_ value: Binding<Double>, in range: ClosedRange<Double>, step: Double.Stride, suffix: String) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: range, step: step)
            MaycastValueLabel(String(format: "%.1f%@", value.wrappedValue, suffix))
        }
    }

    private func assetRow(label: String, path: String?, durationSec: Double) -> some View {
        let attached = path != nil
        return HStack(spacing: 10) {
            MaycastIconTile(
                systemName: attached ? "checkmark.seal.fill" : "circle.dashed",
                size: 28, iconSize: 13,
                tone: attached ? .success : .neutral,
                cornerRadius: MaycastRadius.inner
            )
            Text(label)
                .font(MaycastFont.mono(12.5, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
                .frame(width: 80, alignment: .leading)
            Text(path ?? "not attached")
                .font(MaycastFont.mono(11))
                .foregroundStyle(attached ? MaycastPalette.fg3 : MaycastPalette.fg4)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if attached, durationSec > 0 {
                Text(MaycastDuration.format(durationSec))
                    .font(MaycastFont.mono(11.5))
                    .foregroundStyle(MaycastPalette.fg2)
            }
        }
    }

    // MARK: transition preview

    @ViewBuilder
    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                previewButton(label: "Preview intro transition", kind: .intro, disabled: overlay.introPath == nil)
                previewButton(label: "Preview outro transition", kind: .outro, disabled: overlay.outroPath == nil)
                Spacer()
                if case .playing = preview {
                    Button {
                        onStopPreview?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill").font(.system(size: 10))
                            Text("Stop")
                        }
                    }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                }
            }
            switch preview {
            case .rendering(let kind):
                MaycastStatusBanner(tone: .info, title: "Rendering \(kind == .intro ? "intro" : "outro") transition…", spinning: true)
            case .playing(let kind):
                MaycastStatusBanner(tone: .progress, icon: "waveform", title: "Playing \(kind == .intro ? "intro" : "outro") transition")
            case .failed(let message):
                MaycastStatusBanner(tone: .danger, icon: "exclamationmark.triangle.fill", title: "Preview failed", detail: message)
            case .idle:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func previewButton(label: String, kind: MixOverlapKind, disabled: Bool) -> some View {
        let activeForThis: Bool = {
            switch preview {
            case .rendering(let k), .playing(let k): return k == kind
            default: return false
            }
        }()
        let isPlayingThis: Bool = {
            if case .playing(let k) = preview { return k == kind }
            return false
        }()
        Button { onPreview?(kind) } label: {
            HStack(spacing: 5) {
                Image(systemName: activeForThis ? "waveform" : "play.circle")
                    .font(.system(size: 11))
                    .symbolEffect(.pulse, isActive: isPlayingThis)
                Text(label)
            }
        }
        .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
        .disabled(disabled || (preview != .idle && !activeForThis))
    }

    // MARK: output

    private var outputSection: some View {
        MaycastFormField("Output path", hint: "Relative to the episode bundle. Chapters are embedded as ID3 tags.") {
            MaycastTextFieldBox(icon: "folder") {
                TextField("exports/episode.mp3", text: $outputPath)
                    .font(MaycastFont.mono(12))
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
                title: "Ready to mix",
                detail: tracks.isEmpty ? nil : "Writes \(outputPath.isEmpty ? "the output file" : outputPath) inside the episode bundle."
            )
        case .mixing(let progress):
            VStack(spacing: 8) {
                MaycastStatusBanner(tone: .progress, title: "Mixing…", spinning: true)
                MaycastProgressRows(rows: [MaycastProgressRow(id: "mix", value: progress)])
            }
        case .completed(let path, let duration, let byteSize):
            MaycastStatusBanner(
                tone: .success, icon: "checkmark.seal.fill",
                title: "Mix complete",
                detail: "\(path) · \(MaycastDuration.format(duration)) · \(formattedSize(byteSize))"
            )
        case .failed(let message):
            MaycastStatusBanner(
                tone: .danger, icon: "exclamationmark.triangle.fill",
                title: "Mix failed",
                detail: message
            )
        }
    }

    // MARK: footer actions

    @ViewBuilder
    private var leadingActions: some View {
        if case .completed = state {
            Button {
                onReveal?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 12))
                    Text("Reveal in Finder")
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if case .mixing = state, onCancel != nil {
            Button("Cancel") { onCancel?() }
                .buttonStyle(MaycastDestructiveButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        Button(action: { onMix?() }) {
            HStack(spacing: 6) {
                if !disableMixButton {
                    Image(systemName: "square.stack.3d.down.forward").font(.system(size: 12))
                }
                Text(mixLabel)
            }
        }
        .buttonStyle(MaycastPrimaryButtonStyle(glow: !disableMixButton))
        .keyboardShortcut(.defaultAction)
        .disabled(disableMixButton)
    }

    private var mixLabel: String {
        switch state {
        case .mixing: return "Mixing…"
        case .completed: return "Mix again"
        default: return "Mix"
        }
    }

    private var disableMixButton: Bool {
        if case .mixing = state { return true }
        return tracks.isEmpty || outputPath.isEmpty
    }

    // MARK: - Formatting

    private func formattedSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return "\(bytes / 1024) KB"
    }
}

// MARK: - Previews

#if DEBUG
private let mixSampleTracks: [MixTrackSummary] = [
    MixTrackSummary(id: "host",  currentPath: Track.sampleHost.current,  duration: 1820.5),
    MixTrackSummary(id: "guest", currentPath: Track.sampleGuest.current, duration: 1822.0),
]

private let mixSampleOverlay = MixOverlaySettings(
    introPath: "assets/intro.mp3",
    outroPath: "assets/outro.mp3",
    introOffsetSec: 2.0,
    outroOffsetSec: 5.0,
    duckingGainDB: -12,
    duckingFadeSec: 0.5
)

private struct MixPreviewHost: View {
    @State var outputPath: String = "exports/ep01.mp3"
    @State var state: MixState
    @State var overlay: MixOverlaySettings = mixSampleOverlay
    var tracks: [MixTrackSummary] = mixSampleTracks
    var introDurationSec: Double = 61.7
    var outroDurationSec: Double = 51.6
    var preview: MixPreviewState = .idle
    var size: CGSize = CGSize(width: 1100, height: 760)

    var body: some View {
        MixView(
            episodeID: EpisodeBundle.sampleWithTracks.episode.id,
            tracks: tracks,
            outputPath: $outputPath,
            state: $state,
            overlay: $overlay,
            introDurationSec: introDurationSec,
            outroDurationSec: outroDurationSec,
            preview: preview,
            onCancel: {}
        )
        .frame(width: size.width, height: size.height)
    }
}

#Preview("Idle") {
    MixPreviewHost(state: .idle)
}

#Preview("Idle — no intro / outro") {
    MixPreviewHost(state: .idle, overlay: .defaults, introDurationSec: 0, outroDurationSec: 0)
}

#Preview("Mixing") {
    MixPreviewHost(state: .mixing(progress: 0.45))
}

#Preview("Completed") {
    MixPreviewHost(state: .completed(path: "exports/ep01.mp3", duration: 1897.3, byteSize: 30_412_032))
}

#Preview("Failed") {
    MixPreviewHost(state: .failed(message: "Service failed: no track audio found to mix"))
}

#Preview("Preview rendering") {
    MixPreviewHost(state: .idle, preview: .rendering(kind: .intro))
}

#Preview("Preview playing") {
    MixPreviewHost(state: .idle, preview: .playing(kind: .outro))
}

#Preview("Preview failed") {
    MixPreviewHost(state: .idle, preview: .failed(message: "intro asset missing: assets/intro.mp3"))
}

#Preview("Empty — no tracks") {
    MixPreviewHost(state: .idle, tracks: [])
}

#Preview("Compact window") {
    MixPreviewHost(state: .idle, size: CGSize(width: 720, height: 520))
}
#endif
