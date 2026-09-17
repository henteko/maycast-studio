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

/// Multi-track Polish pane backed by the Auphonic Multitrack API.
///
/// Rendered inside `MaycastOperationShell`: the shell owns the back button,
/// title, status banner and the single primary action. This view only
/// supplies the content (API key, speakers, effects) and the state-driven
/// footer pieces.
///
/// One press of **Send to Auphonic** uploads every track in `tracks` as a
/// separate speaker file, lets Auphonic run the chosen algorithms, then
/// downloads the per-speaker cleaned tracks and writes one new generation
/// per track.
struct PolishView: View {
    let episodeID: String
    let tracks: [PolishTrackSummary]
    let apiKeyStatus: ApiKeyStatus
    @Binding var settings: PolishSettings
    @Binding var status: PolishStatus

    var onApply: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onConfigureAPIKey: (() -> Void)? = nil
    /// Return to the episode overview (the shell's back button).
    var onBack: (() -> Void)? = nil

    enum ApiKeyStatus: Sendable, Equatable {
        case configured(label: String)  // e.g. "configured (••••abcd)"
        case missing
    }

    var body: some View {
        MaycastOperationShell(
            episodeID: episodeID,
            icon: "wand.and.stars",
            tone: .mint,
            title: "Polish",
            subtitle: "Clean up every track via Auphonic",
            onBack: { onBack?() },
            accessory: { headerChips },
            content: { content },
            status: { statusSection },
            leading: { resetButton },
            trailing: { trailingActions }
        )
    }

    // MARK: header chips

    private var headerChips: some View {
        HStack(spacing: 6) {
            if case .missing = apiKeyStatus {
                MaycastChip("API key missing", tone: .warning) {
                    Image(systemName: "key.slash").font(.system(size: 10))
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
                    title: "Nothing to polish",
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
                    apiKeyBanner
                    speakersSection
                    effectsSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: API key

    @ViewBuilder
    private var apiKeyBanner: some View {
        switch apiKeyStatus {
        case .configured(let label):
            MaycastStatusBanner(
                tone: .success,
                icon: "key.fill",
                title: "Auphonic API key",
                detail: "\(label) — runs consume your Auphonic account's processing time."
            ) {
                Button("Change…") { onConfigureAPIKey?() }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            }
        case .missing:
            MaycastStatusBanner(
                tone: .warning,
                icon: "key.slash",
                title: "Auphonic API key not set",
                detail: "Issue one at https://auphonic.com/engine/account/ — it is stored in your Keychain."
            ) {
                Button("Configure…") { onConfigureAPIKey?() }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            }
        }
    }

    // MARK: speakers

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Speakers", trailing: "uploaded as one multitrack production")
            MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                VStack(spacing: 8) {
                    ForEach(tracks) { track in
                        MaycastTrackRow(id: track.id, path: track.currentPath, duration: track.duration)
                    }
                }
            }
        }
    }

    // MARK: effects

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Loudness") {
                MaycastSettingRow(icon: "speaker.wave.2", "Loudness target", hint: "Integrated loudness of every cleaned track", layout: .stacked) {
                    HStack(spacing: 12) {
                        Slider(value: $settings.loudnessTarget, in: -23 ... -14, step: 0.5)
                        MaycastValueLabel(String(format: "%.1f LUFS", settings.loudnessTarget))
                    }
                }
                MaycastHairline()
                MaycastSettingRow(icon: "slider.horizontal.3", "Adaptive Leveler", hint: "Balances loudness across speakers") {
                    toggle($settings.levelerEnabled)
                }
            }

            settingsGroup("Cleanup") {
                MaycastSettingRow(icon: "wand.and.sparkles", "Denoise") {
                    toggle($settings.denoiseEnabled)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "list.bullet", "Denoise method", enabled: settings.denoiseEnabled) {
                    Picker("Denoise method", selection: $settings.denoiseMethod) {
                        ForEach(DenoiseMethod.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "wind", "Debreath", hint: "Attenuates breaths and sniffles") {
                    Picker("Debreath amount", selection: $settings.debreathAmount) {
                        ForEach(DebreathAmount.allCases, id: \.self) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "waveform.path", "High-pass filter", hint: "Removes low-frequency rumble") {
                    toggle($settings.hipfilterEnabled)
                }
            }

            settingsGroup("Cuts") {
                MaycastSettingRow(icon: "scissors", "Filler word cutter", hint: "え, あの, …") {
                    toggle($settings.fillerCutterEnabled)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "scissors", "Silence cutter") {
                    toggle($settings.silenceCutterEnabled)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "scissors", "Cough cutter") {
                    toggle($settings.coughCutterEnabled)
                }
            }

            settingsGroup("Advanced") {
                MaycastSettingRow(icon: "tray.full", "Keep production on Auphonic dashboard", hint: "For debugging — costs storage on your account") {
                    toggle($settings.keepProduction)
                }
            }
        }
    }

    private func settingsGroup<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        let body = rows()
        return VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel(title)
            MaycastCard(padding: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)) {
                VStack(spacing: 0) { body }
            }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    // MARK: status (footer)

    @ViewBuilder
    private var statusSection: some View {
        switch status {
        case .idle:
            MaycastStatusBanner(
                tone: .idle, icon: "circle.dashed",
                title: "Ready",
                detail: tracks.isEmpty ? nil : "\(tracks.count) track\(tracks.count == 1 ? "" : "s") will be uploaded, cleaned and written as a new generation."
            )
        case .needsApiKey:
            MaycastStatusBanner(
                tone: .warning, icon: "exclamationmark.triangle.fill",
                title: "Set an Auphonic API key to continue."
            )
        case .uploading(let progress):
            VStack(spacing: 8) {
                MaycastStatusBanner(tone: .info, title: "Uploading to Auphonic…", spinning: true)
                MaycastProgressRows(rows: progressRows(progress), tone: .info)
            }
        case .processing(let label):
            MaycastStatusBanner(
                tone: .progress,
                title: "Auphonic processing",
                detail: label.isEmpty ? "running" : label,
                spinning: true
            )
        case .downloading(let progress):
            VStack(spacing: 8) {
                MaycastStatusBanner(tone: .info, title: "Downloading cleaned tracks…", spinning: true)
                MaycastProgressRows(rows: progressRows(progress), tone: .info)
            }
        case .completed(let results):
            VStack(spacing: 8) {
                MaycastStatusBanner(
                    tone: .success, icon: "checkmark.seal.fill",
                    title: "Polish complete (\(results.count) track\(results.count == 1 ? "" : "s"))",
                    detail: "Each speaker gained a new generation. Use Undo on the episode to revert."
                )
                VStack(spacing: 8) {
                    ForEach(results) { r in
                        MaycastTrackRow(id: r.id, path: r.generationPath, tone: .success, icon: "checkmark")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                        .fill(MaycastPalette.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MaycastRadius.control, style: .continuous)
                        .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
                )
            }
        case .failed(let message):
            MaycastStatusBanner(
                tone: .danger, icon: "exclamationmark.triangle.fill",
                title: "Polish failed",
                detail: message
            )
        }
    }

    private func progressRows(_ progress: [String: Double]) -> [MaycastProgressRow] {
        tracks.map { MaycastProgressRow(id: $0.id, value: progress[$0.id] ?? 0) }
    }

    // MARK: footer actions

    private var resetButton: some View {
        Button("Reset to defaults") { settings = .defaults }
            .buttonStyle(MaycastGhostButtonStyle())
            .disabled(settings == .defaults || status.isActive)
    }

    @ViewBuilder
    private var trailingActions: some View {
        if status.isActive {
            Button("Cancel") { onCancel?() }
                .buttonStyle(MaycastDestructiveButtonStyle())
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

    private var applyLabel: String {
        switch status {
        case .uploading: return "Uploading…"
        case .processing: return "Processing…"
        case .downloading: return "Downloading…"
        case .completed: return "Polish again"
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
    PolishTrackSummary(id: "host",  currentPath: Track.sampleHost.current,  duration: 1820.5),
    PolishTrackSummary(id: "guest", currentPath: Track.sampleGuest.current, duration: 1822.0),
]

private let polishSampleKey = PolishView.ApiKeyStatus.configured(label: "••••2f1a")

private struct PolishPreviewHost: View {
    @State var settings: PolishSettings = .defaults
    @State var status: PolishStatus
    var tracks: [PolishTrackSummary] = polishSampleTracks
    var apiKeyStatus: PolishView.ApiKeyStatus = polishSampleKey
    var size: CGSize = CGSize(width: 1100, height: 760)

    var body: some View {
        PolishView(
            episodeID: EpisodeBundle.sampleWithTracks.episode.id,
            tracks: tracks,
            apiKeyStatus: apiKeyStatus,
            settings: $settings,
            status: $status
        )
        .frame(width: size.width, height: size.height)
    }
}

#Preview("Idle — API key configured") {
    PolishPreviewHost(status: .idle)
}

#Preview("Idle — needs API key") {
    PolishPreviewHost(status: .needsApiKey, apiKeyStatus: .missing)
}

#Preview("Uploading") {
    PolishPreviewHost(status: .uploading(progress: ["host": 0.72, "guest": 0.31]))
}

#Preview("Processing") {
    PolishPreviewHost(status: .processing(statusString: "Audio Algorithms"))
}

#Preview("Downloading") {
    PolishPreviewHost(status: .downloading(progress: ["host": 1.0, "guest": 0.42]))
}

#Preview("Completed") {
    PolishPreviewHost(status: .completed(results: [
        PolishTrackResult(id: "host",  generationPath: "intermediate/host/004_polish.wav"),
        PolishTrackResult(id: "guest", generationPath: "intermediate/guest/002_polish.wav"),
    ]))
}

#Preview("Failed") {
    PolishPreviewHost(status: .failed(message: "Auphonic API: HTTP 401 — invalid API key"))
}

#Preview("Empty — no tracks") {
    PolishPreviewHost(status: .idle, tracks: [])
}

#Preview("Compact window") {
    PolishPreviewHost(status: .idle, size: CGSize(width: 720, height: 520))
}
#endif
