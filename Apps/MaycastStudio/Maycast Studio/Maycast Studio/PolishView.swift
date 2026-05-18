import SwiftUI
import MaycastCore

// MARK: - Models

/// Summary of a track for display in the Polish panel.
struct PolishTrackSummary: Identifiable, Sendable {
    let id: String
    let currentPath: String
    let duration: TimeInterval
}

/// Per-track result of a polish run. Generation path points at the cleaned
/// track that Auphonic returned (per-speaker, not the master mix).
struct PolishTrackResult: Identifiable, Sendable, Equatable {
    let id: String
    let generationPath: String
}

/// Auphonic denoise modes — passed through as-is in the algorithms payload.
/// `dynamic` is the default for spoken-word podcasts.
enum DenoiseMethod: String, CaseIterable, Sendable, Equatable {
    case dynamic
    case staticMode = "static"
    case speechIsolation = "speech_isolation"

    var label: String {
        switch self {
        case .dynamic: return "Dynamic"
        case .staticMode: return "Static"
        case .speechIsolation: return "Speech isolation"
        }
    }
}

/// Allowed Auphonic debreath values (dB attenuation, or 0 = off).
/// `100` is "maximum" in Auphonic's docs.
enum DebreathAmount: Int, CaseIterable, Sendable, Equatable {
    case off = 0
    case db3 = 3
    case db6 = 6
    case db9 = 9
    case db12 = 12
    case db15 = 15
    case db18 = 18
    case db24 = 24
    case db30 = 30
    case db36 = 36
    case max = 100

    var label: String {
        self == .off ? "Off" : (self == .max ? "Max" : "\(rawValue) dB")
    }
}

/// Settings for an Auphonic multitrack production. Mirrors the algorithm
/// fields described at https://auphonic.com/help/api/multitrack.html .
struct PolishSettings: Equatable, Sendable {
    // Loudness
    var loudnessTarget: Double  // LUFS, range -23..-14 (Auphonic accepts wider but this keeps the UI sensible)

    // Adaptive leveler (per-track auto level)
    var levelerEnabled: Bool

    // Denoise
    var denoiseEnabled: Bool
    var denoiseMethod: DenoiseMethod

    // Cuts
    var fillerCutterEnabled: Bool
    var silenceCutterEnabled: Bool
    var coughCutterEnabled: Bool

    // Breath / sniffle attenuation
    var debreathAmount: DebreathAmount

    // High-pass filter to remove low-frequency rumble. Auphonic recommends on.
    var hipfilterEnabled: Bool

    // When true, the production is left on Auphonic's dashboard after a
    // successful run instead of being deleted. Useful for diagnosing why a
    // track came out unexpectedly (silence, low level, etc.).
    var keepProduction: Bool

    static let defaults = PolishSettings(
        loudnessTarget: -16,
        levelerEnabled: true,
        denoiseEnabled: true,
        denoiseMethod: .dynamic,
        fillerCutterEnabled: true,
        silenceCutterEnabled: true,
        coughCutterEnabled: true,
        debreathAmount: .max,
        hipfilterEnabled: true,
        keepProduction: false
    )
}

/// Lifecycle of an Auphonic polish run.
///
/// `uploading`/`downloading` carry per-track progress (0.0–1.0).
/// `processing` carries a human-readable status string from Auphonic
/// (e.g. "Audio Algorithms", "Encoding") that updates on every poll.
enum PolishStatus: Sendable, Equatable {
    case idle
    case uploading(progress: [String: Double])
    case processing(statusString: String)
    case downloading(progress: [String: Double])
    case completed(results: [PolishTrackResult])
    case failed(message: String)
    case needsApiKey

    var isActive: Bool {
        switch self {
        case .uploading, .processing, .downloading: return true
        default: return false
        }
    }
}

// MARK: - PolishView

/// Multi-track Polish panel backed by the Auphonic Multitrack API.
///
/// One press of **Apply** uploads every track in `tracks` as a separate
/// speaker file, lets Auphonic run the chosen algorithms, then downloads the
/// per-speaker cleaned tracks (zipped) and writes one new generation per
/// track. The Maycast Mix flow can then combine those cleaned tracks.
struct PolishView: View {
    let tracks: [PolishTrackSummary]
    let apiKeyStatus: ApiKeyStatus
    @Binding var settings: PolishSettings
    @Binding var status: PolishStatus

    var onApply: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onConfigureAPIKey: (() -> Void)? = nil

    enum ApiKeyStatus: Sendable, Equatable {
        case configured(label: String)  // e.g. "configured (••••abcd)"
        case missing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            apiKeySection
            tracksSection
            ScrollView { effectsSection.padding(.trailing, 6) }
                .frame(maxHeight: 320)
            statusSection
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .background(MaycastPalette.bg1)
        .frame(minWidth: 600, minHeight: 720)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MaycastIconTile(systemName: "wand.and.stars", tone: .mint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Polish").font(MaycastFont.display(19, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text("via Auphonic")
                        .font(MaycastFont.body(12))
                        .foregroundStyle(MaycastPalette.fg3)
                    Spacer()
                    MaycastChip("\(tracks.count) track\(tracks.count == 1 ? "" : "s")", tone: .mint) {
                        Image(systemName: "rectangle.stack").font(.system(size: 10))
                    }
                }
                Text("Cleans each track via the Auphonic Multitrack API and writes one new generation per speaker. Auphonic is a paid SaaS — running this consumes your account's processing time.")
                    .font(MaycastFont.body(12.5))
                    .foregroundStyle(MaycastPalette.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: API key

    private var apiKeySection: some View {
        let missing = apiKeyStatus == .missing
        return HStack(spacing: 10) {
            Image(systemName: missing ? "key.slash" : "key.fill")
                .foregroundStyle(missing ? Color(hex: 0xC4760A) : MaycastPalette.mint600)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                switch apiKeyStatus {
                case .configured(let label):
                    Text("Auphonic API key")
                        .font(MaycastFont.body(12.5, weight: .semibold))
                        .foregroundStyle(MaycastPalette.mint800)
                    Text(label)
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.mint700)
                case .missing:
                    Text("Auphonic API key not set")
                        .font(MaycastFont.body(12.5, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x7A4A06))
                    Text("Configure one from https://auphonic.com/engine/account/")
                        .font(MaycastFont.body(11))
                        .foregroundStyle(Color(hex: 0xC4760A))
                }
            }
            Spacer()
            Button(missing ? "Configure…" : "Change…") {
                onConfigureAPIKey?()
            }
            .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(missing ? MaycastPalette.warning.opacity(0.13) : MaycastPalette.mint50)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(missing ? MaycastPalette.warning.opacity(0.3) : MaycastPalette.mint200, lineWidth: 0.5)
        )
    }

    // MARK: tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers — uploaded as multi-track to Auphonic")
                .font(MaycastFont.body(10.5, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(MaycastPalette.fg3)
            MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14), cornerRadius: 10) {
                VStack(spacing: 8) {
                    ForEach(tracks) { track in
                        HStack(spacing: 10) {
                            MaycastIconTile(systemName: "waveform", size: 28, iconSize: 13, tone: .mint, cornerRadius: 7)
                            Text(track.id)
                                .font(MaycastFont.mono(12.5, weight: .semibold))
                                .foregroundStyle(MaycastPalette.fg1)
                                .frame(width: 80, alignment: .leading)
                            Text(track.currentPath)
                                .font(MaycastFont.mono(11))
                                .foregroundStyle(MaycastPalette.fg3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(String(format: "%.1fs", track.duration))
                                .font(MaycastFont.mono(11.5))
                                .foregroundStyle(MaycastPalette.fg2)
                        }
                    }
                }
            }
        }
    }

    // MARK: effects

    private var effectsSection: some View {
        MaycastCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16), cornerRadius: 12) {
            effectsContent
        }
    }

    private var effectsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Loudness
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "speaker.wave.2")
                    Text("Loudness target").font(.callout.weight(.medium))
                }
                HStack {
                    Slider(value: $settings.loudnessTarget, in: -23 ... -14, step: 0.5)
                    Text(String(format: "%.1f LUFS", settings.loudnessTarget))
                        .frame(width: 90, alignment: .trailing)
                        .font(.body.monospacedDigit())
                }
            }

            // Adaptive leveler
            Toggle(isOn: $settings.levelerEnabled) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("Adaptive Leveler")
                    Text("balances loudness across speakers")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)

            // Denoise
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $settings.denoiseEnabled) {
                    HStack {
                        Image(systemName: "wand.and.sparkles")
                        Text("Denoise")
                    }
                }
                .toggleStyle(.switch)
                HStack {
                    Text("Method").frame(width: 70, alignment: .leading)
                        .foregroundStyle(settings.denoiseEnabled ? .primary : .secondary)
                    Picker("Denoise method", selection: $settings.denoiseMethod) {
                        ForEach(DenoiseMethod.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(!settings.denoiseEnabled)
                }
            }

            // Cuts
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "scissors")
                    Text("Cuts").font(.callout.weight(.medium))
                }
                Toggle("Filler word cutter (え, あの, …)", isOn: $settings.fillerCutterEnabled).toggleStyle(.switch)
                Toggle("Silence cutter", isOn: $settings.silenceCutterEnabled).toggleStyle(.switch)
                Toggle("Cough cutter", isOn: $settings.coughCutterEnabled).toggleStyle(.switch)
            }

            // Breath / hipfilter
            HStack {
                Text("Debreath amount").frame(width: 140, alignment: .leading)
                Picker("Debreath amount", selection: $settings.debreathAmount) {
                    ForEach(DebreathAmount.allCases, id: \.self) { d in
                        Text(d.label).tag(d)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Toggle(isOn: $settings.hipfilterEnabled) {
                HStack {
                    Image(systemName: "waveform.path")
                    Text("High-pass filter (rumble removal)")
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $settings.keepProduction) {
                HStack {
                    Image(systemName: "tray.full")
                    Text("Keep production on Auphonic dashboard")
                    Text("(for debugging — costs storage)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: status

    @ViewBuilder
    private var statusSection: some View {
        switch status {
        case .idle:
            statusRow(tone: .idle, icon: "circle.dashed", title: "Ready", subtitle: nil)
        case .needsApiKey:
            statusRow(tone: .warning, icon: "exclamationmark.triangle.fill",
                      title: "Set an Auphonic API key to continue.", subtitle: nil)
        case .uploading(let progress):
            statusBlock(tone: .info, label: "Uploading to Auphonic…",
                        icon: "arrow.up.circle", perTrack: progress)
        case .processing(let label):
            statusRow(tone: .progress, icon: "wand.and.stars",
                      title: "Auphonic processing",
                      subtitle: label.isEmpty ? "running" : label, spinning: true)
        case .downloading(let progress):
            statusBlock(tone: .info, label: "Downloading cleaned tracks…",
                        icon: "arrow.down.circle", perTrack: progress)
        case .completed(let results):
            VStack(alignment: .leading, spacing: 8) {
                statusRow(tone: .success, icon: "checkmark.seal.fill",
                          title: "Polish complete (\(results.count) track\(results.count == 1 ? "" : "s"))",
                          subtitle: nil)
                ForEach(results) { r in
                    HStack(spacing: 8) {
                        Text(r.id).font(MaycastFont.mono(11.5, weight: .semibold))
                            .foregroundStyle(MaycastPalette.fg1)
                            .frame(width: 80, alignment: .leading)
                        Text(r.generationPath)
                            .font(MaycastFont.mono(11))
                            .foregroundStyle(MaycastPalette.mint700)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                statusRow(tone: .danger, icon: "exclamationmark.triangle.fill",
                          title: "Polish failed", subtitle: nil)
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

    private enum StatusTone { case idle, info, progress, success, warning, danger }

    private func statusRow(tone: StatusTone, icon: String, title: String, subtitle: String?, spinning: Bool = false) -> some View {
        HStack(spacing: 10) {
            if spinning {
                ProgressView().controlSize(.small)
                    .tint(toneFG(tone))
            } else {
                Image(systemName: icon)
                    .foregroundStyle(toneFG(tone))
                    .font(.system(size: 15))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(MaycastFont.body(12.5, weight: .semibold))
                    .foregroundStyle(toneFG(tone))
                if let subtitle {
                    Text(subtitle)
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.fg3)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(toneBG(tone))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(toneBorder(tone), lineWidth: 0.5)
        )
    }

    private func statusBlock(tone: StatusTone, label: String, icon: String, perTrack: [String: Double]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow(tone: tone, icon: icon, title: label, subtitle: nil, spinning: true)
            VStack(spacing: 6) {
                ForEach(tracks) { track in
                    let value = perTrack[track.id] ?? 0
                    HStack(spacing: 10) {
                        Text(track.id)
                            .font(MaycastFont.mono(11.5, weight: .semibold))
                            .foregroundStyle(MaycastPalette.fg1)
                            .frame(width: 80, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(MaycastPalette.ink100)
                                Capsule().fill(MaycastPalette.mint500)
                                    .frame(width: geo.size.width * CGFloat(value))
                            }
                        }
                        .frame(height: 6)
                        Text("\(Int(value * 100))%")
                            .font(MaycastFont.mono(10.5, weight: .semibold))
                            .foregroundStyle(MaycastPalette.fg3)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MaycastPalette.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
            )
        }
    }

    private func toneBG(_ tone: StatusTone) -> Color {
        switch tone {
        case .idle:     return MaycastPalette.bg2
        case .info:     return MaycastPalette.sky50
        case .progress: return MaycastPalette.mint50
        case .success:  return MaycastPalette.mint50
        case .warning:  return MaycastPalette.warning.opacity(0.13)
        case .danger:   return MaycastPalette.danger.opacity(0.10)
        }
    }
    private func toneFG(_ tone: StatusTone) -> Color {
        switch tone {
        case .idle:     return MaycastPalette.fg2
        case .info:     return MaycastPalette.sky700
        case .progress: return MaycastPalette.mint700
        case .success:  return MaycastPalette.mint700
        case .warning:  return Color(hex: 0xC4760A)
        case .danger:   return MaycastPalette.danger
        }
    }
    private func toneBorder(_ tone: StatusTone) -> Color {
        switch tone {
        case .idle:     return MaycastPalette.border1
        case .info:     return MaycastPalette.sky200
        case .progress, .success: return MaycastPalette.mint200
        case .warning:  return MaycastPalette.warning.opacity(0.3)
        case .danger:   return MaycastPalette.danger.opacity(0.25)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if status.isActive {
                Button("Cancel") { onCancel?() }
                    .buttonStyle(MaycastSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Button(action: { onApply?() }) {
                HStack(spacing: 6) {
                    if !disableApply {
                        Image(systemName: "wand.and.stars").font(.system(size: 12))
                    }
                    Text(applyLabel)
                }
            }
            .buttonStyle(MaycastPrimaryButtonStyle(glow: !disableApply))
            .keyboardShortcut(.defaultAction)
            .disabled(disableApply)
        }
    }

    private var applyLabel: String {
        switch status {
        case .uploading: return "Uploading…"
        case .processing: return "Processing…"
        case .downloading: return "Downloading…"
        default: return "Send to Auphonic"
        }
    }

    private var disableApply: Bool {
        if status.isActive { return true }
        if tracks.isEmpty { return true }
        if case .missing = apiKeyStatus { return true }
        return false
    }
}

// MARK: - Previews

#if DEBUG
private let polishSampleTracks: [PolishTrackSummary] = [
    PolishTrackSummary(id: "host",  currentPath: "intermediate/host/003_polish.wav",  duration: 1820.5),
    PolishTrackSummary(id: "guest", currentPath: "intermediate/guest/001_import.wav", duration: 1822.0),
]

private struct PolishPreviewHost: View {
    @State var settings: PolishSettings = .defaults
    @State var status: PolishStatus
    let tracks: [PolishTrackSummary]
    let apiKeyStatus: PolishView.ApiKeyStatus

    var body: some View {
        PolishView(
            tracks: tracks,
            apiKeyStatus: apiKeyStatus,
            settings: $settings,
            status: $status
        )
    }
}

#Preview("Idle — API key configured") {
    PolishPreviewHost(
        status: .idle,
        tracks: polishSampleTracks,
        apiKeyStatus: .configured(label: "configured (••••2f1a)")
    )
}

#Preview("Idle — needs API key") {
    PolishPreviewHost(
        status: .needsApiKey,
        tracks: polishSampleTracks,
        apiKeyStatus: .missing
    )
}

#Preview("Uploading") {
    PolishPreviewHost(
        status: .uploading(progress: ["host": 0.72, "guest": 0.31]),
        tracks: polishSampleTracks,
        apiKeyStatus: .configured(label: "configured (••••2f1a)")
    )
}

#Preview("Processing") {
    PolishPreviewHost(
        status: .processing(statusString: "Audio Algorithms"),
        tracks: polishSampleTracks,
        apiKeyStatus: .configured(label: "configured (••••2f1a)")
    )
}

#Preview("Downloading") {
    PolishPreviewHost(
        status: .downloading(progress: ["host": 1.0, "guest": 0.42]),
        tracks: polishSampleTracks,
        apiKeyStatus: .configured(label: "configured (••••2f1a)")
    )
}

#Preview("Completed") {
    PolishPreviewHost(
        status: .completed(results: [
            PolishTrackResult(id: "host",  generationPath: "intermediate/host/004_polish.wav"),
            PolishTrackResult(id: "guest", generationPath: "intermediate/guest/002_polish.wav"),
        ]),
        tracks: polishSampleTracks,
        apiKeyStatus: .configured(label: "configured (••••2f1a)")
    )
}

#Preview("Failed") {
    PolishPreviewHost(
        status: .failed(message: "Auphonic API: HTTP 401 — invalid API key"),
        tracks: polishSampleTracks,
        apiKeyStatus: .configured(label: "configured (••••2f1a)")
    )
}
#endif
