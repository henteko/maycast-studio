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
    /// Optional close callback. When provided, the footer surfaces a styled
    /// Close button so the host sheet doesn't need a separate toolbar Close
    /// rendered outside the sheet chrome.
    var onClose: (() -> Void)? = nil

    private var totalDuration: TimeInterval {
        tracks.map(\.duration).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                tracksSection
                overlaySection
                outputSection
                statusSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(MaycastPalette.ink50)
        }
        .background(MaycastPalette.bg1)
        .frame(minWidth: 620, minHeight: 720)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MaycastIconTile(systemName: "rectangle.stack", tone: .sun)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Mix").font(MaycastFont.display(19, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text("final export").font(MaycastFont.body(12))
                        .foregroundStyle(MaycastPalette.fg3)
                    Spacer()
                    MaycastChip("\(tracks.count) track\(tracks.count == 1 ? "" : "s")", tone: .sun) {
                        Image(systemName: "rectangle.stack").font(.system(size: 10))
                    }
                }
                Text("Combines every polished track with the Show's Intro / Outro into the final broadcast file.")
                    .font(MaycastFont.body(12.5))
                    .foregroundStyle(MaycastPalette.fg2)
            }
        }
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tracks to mix")
                .font(MaycastFont.body(10.5, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(MaycastPalette.fg3)
            MaycastCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14), cornerRadius: 12) {
                VStack(spacing: 6) {
                    ForEach(tracks) { track in
                        HStack(spacing: 10) {
                            Image(systemName: "waveform").foregroundStyle(MaycastPalette.mint600)
                            Text(track.id)
                                .font(MaycastFont.mono(12, weight: .semibold))
                                .foregroundStyle(MaycastPalette.fg1)
                                .frame(width: 80, alignment: .leading)
                            Text(track.currentPath)
                                .font(MaycastFont.mono(11))
                                .foregroundStyle(MaycastPalette.fg3)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(formattedSeconds(track.duration))
                                .font(MaycastFont.mono(11.5))
                                .foregroundStyle(MaycastPalette.fg2)
                        }
                    }
                    Rectangle().fill(MaycastPalette.border1).frame(height: 0.5).padding(.vertical, 2)
                    HStack {
                        Text("Output duration")
                            .font(MaycastFont.body(10.5, weight: .bold))
                            .tracking(0.5)
                            .textCase(.uppercase)
                            .foregroundStyle(MaycastPalette.fg3)
                        Spacer()
                        Text(formattedSeconds(totalDuration))
                            .font(MaycastFont.mono(12, weight: .semibold))
                            .foregroundStyle(MaycastPalette.fg1)
                    }
                    HStack {
                        Text("Output format")
                            .font(MaycastFont.body(10.5, weight: .bold))
                            .tracking(0.5)
                            .textCase(.uppercase)
                            .foregroundStyle(MaycastPalette.fg3)
                        Spacer()
                        Text("16-bit PCM WAV · stereo")
                            .font(MaycastFont.mono(12, weight: .semibold))
                            .foregroundStyle(MaycastPalette.fg1)
                    }
                }
            }
        }
    }

    private var overlaySection: some View {
        let hasIntroOrOutro = overlay.introPath != nil || overlay.outroPath != nil
        return MaycastCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16), cornerRadius: 12) {
            overlayContent(hasIntroOrOutro: hasIntroOrOutro)
        }
    }

    @ViewBuilder
    private func overlayContent(hasIntroOrOutro: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "music.note").foregroundStyle(MaycastPalette.mint600)
                Text("Intro / Outro overlap")
                    .font(MaycastFont.body(12.5, weight: .bold))
                    .foregroundStyle(MaycastPalette.fg1)
                Spacer()
                if !hasIntroOrOutro {
                    Text("Inherits from Show on init")
                        .font(MaycastFont.body(10.5))
                        .foregroundStyle(MaycastPalette.fg4)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Output path")
                .font(MaycastFont.body(10.5, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(MaycastPalette.fg3)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(MaycastPalette.fg3)
                TextField("exports/episode.wav", text: $outputPath)
                    .textFieldStyle(.plain)
                    .font(MaycastFont.mono(12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(MaycastPalette.bg1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(MaycastPalette.border2, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch state {
        case .idle:
            statusPill(tone: .idle, icon: "circle.dashed", title: "Ready to mix")
        case .mixing(let progress):
            VStack(alignment: .leading, spacing: 8) {
                statusPill(tone: .progress, icon: "rectangle.stack", title: "Mixing…", spinning: true)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MaycastPalette.ink100)
                        Capsule().fill(MaycastPalette.mint500)
                            .frame(width: geo.size.width * CGFloat(progress))
                    }
                }
                .frame(height: 8)
            }
        case .completed(let path, let duration, let byteSize):
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [MaycastPalette.mint400, MaycastPalette.mint500],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.white).font(.system(size: 22)))
                    .maycastShadow(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mix complete")
                        .font(MaycastFont.display(16, weight: .bold))
                        .foregroundStyle(MaycastPalette.mint800)
                    Text(path)
                        .font(MaycastFont.mono(12))
                        .foregroundStyle(MaycastPalette.mint700)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(formattedSeconds(duration)) · \(formattedSize(byteSize))")
                    .font(MaycastFont.mono(11))
                    .foregroundStyle(MaycastPalette.mint600)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [MaycastPalette.mint50, Color(hex: 0xF6FFFB)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MaycastPalette.mint200, lineWidth: 0.5)
            )
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                statusPill(tone: .danger, icon: "exclamationmark.triangle.fill", title: "Mix failed")
                Text(message)
                    .font(MaycastFont.mono(11.5))
                    .foregroundStyle(MaycastPalette.danger)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(MaycastPalette.danger.opacity(0.08))
                    )
            }
        }
    }

    private enum MixStatusTone { case idle, progress, danger }

    private func statusPill(tone: MixStatusTone, icon: String, title: String, spinning: Bool = false) -> some View {
        HStack(spacing: 10) {
            if spinning {
                ProgressView().controlSize(.small)
                    .tint(fg(tone))
            } else {
                Image(systemName: icon)
                    .foregroundStyle(fg(tone))
            }
            Text(title)
                .font(MaycastFont.body(12.5, weight: .semibold))
                .foregroundStyle(fg(tone))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bg(tone))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(border(tone), lineWidth: 0.5)
        )
    }
    private func bg(_ tone: MixStatusTone) -> Color {
        switch tone {
        case .idle:     return MaycastPalette.bg2
        case .progress: return MaycastPalette.mint50
        case .danger:   return MaycastPalette.danger.opacity(0.10)
        }
    }
    private func fg(_ tone: MixStatusTone) -> Color {
        switch tone {
        case .idle:     return MaycastPalette.fg2
        case .progress: return MaycastPalette.mint700
        case .danger:   return MaycastPalette.danger
        }
    }
    private func border(_ tone: MixStatusTone) -> Color {
        switch tone {
        case .idle:     return MaycastPalette.border1
        case .progress: return MaycastPalette.mint200
        case .danger:   return MaycastPalette.danger.opacity(0.25)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let onClose {
                Button("Close") { onClose() }
                    .buttonStyle(MaycastSecondaryButtonStyle())
                    .keyboardShortcut("w", modifiers: .command)
            }
            Spacer()
            if case .completed = state {
                Button("Reveal in Finder") { onReveal?() }
                    .buttonStyle(MaycastSecondaryButtonStyle())
            }
            Button(action: { onMix?() }) {
                HStack(spacing: 6) {
                    if !disableMixButton {
                        Image(systemName: "square.stack.3d.down.forward").font(.system(size: 12))
                    }
                    switch state {
                    case .mixing: Text("Mixing…")
                    case .completed: Text("Mix again")
                    default: Text("Mix")
                    }
                }
            }
            .buttonStyle(MaycastPrimaryButtonStyle(glow: !disableMixButton))
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
#endif
