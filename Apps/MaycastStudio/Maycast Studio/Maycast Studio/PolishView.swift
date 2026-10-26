import SwiftUI
import MaycastCore

// MARK: - Models

/// Summary of a track for display in the Polish panel.
struct PolishTrackSummary: Identifiable, Sendable {
    let id: String
    let currentPath: String
    let duration: TimeInterval
    var hasVideo: Bool = false
}

/// Per-track result of a polish run. Generation path points at the cleaned
/// track the service returned (per-speaker, not the master mix).
struct PolishTrackResult: Identifiable, Sendable, Equatable {
    let id: String
    let generationPath: String
}

/// Labels for the Core option enums (Core stays UI-string free).
extension AuphonicPolishOptions.DenoiseMethod {
    var label: String {
        switch self {
        case .dynamic: return "Dynamic"
        case .staticMode: return "Static"
        case .speechIsolation: return "Speech isolation"
        }
    }
}

extension AuphonicPolishOptions.DebreathAmount {
    var label: String {
        self == .off ? "Off" : (self == .max ? "Max" : "\(rawValue) dB")
    }
}

extension CleanvoicePolishOptions.Breath {
    var label: String {
        switch self {
        case .off: return "Off"
        case .natural: return "Natural"
        case .legacy: return "Legacy"
        case .full: return "Full"
        }
    }
}

/// UI-facing description of each polish service.
extension PolishProvider {
    var apiKeyService: ApiKeyService {
        switch self {
        case .auphonic: return .auphonic
        case .cleanvoice: return .cleanvoice
        }
    }

    var tagline: String {
        switch self {
        case .auphonic: return "Leveler, denoise and filler / silence / cough cutters."
        case .cleanvoice: return "Filler, stutter, mouth-sound and breath removal tuned for spoken word."
        }
    }
}

/// Settings for the Polish pane: which service runs, plus each service's own
/// options (kept side by side so switching back and forth loses nothing).
struct PolishSettings: Equatable, Sendable {
    var provider: PolishProvider
    var auphonic: AuphonicPolishOptions
    var cleanvoice: CleanvoicePolishOptions

    static let defaults = PolishSettings(provider: .auphonic, auphonic: .defaults, cleanvoice: .defaults)

    /// "Reset to defaults" only touches the selected service's options.
    var isAtProviderDefaults: Bool {
        switch provider {
        case .auphonic: return auphonic == .defaults
        case .cleanvoice: return cleanvoice == .defaults
        }
    }

    mutating func resetProviderOptions() {
        switch provider {
        case .auphonic: auphonic = .defaults
        case .cleanvoice: cleanvoice = .defaults
        }
    }
}

/// Lifecycle of a polish run.
///
/// `uploading`/`downloading` carry per-track progress (0.0–1.0).
/// `processing` carries a human-readable status string from the service
/// (e.g. "Audio Algorithms", "EDITING") that updates on every poll.
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

    init(_ progress: PolishProgress) {
        switch progress {
        case .uploading(let p): self = .uploading(progress: p)
        case .processing(let label): self = .processing(statusString: label)
        case .downloading(let p): self = .downloading(progress: p)
        }
    }
}

// MARK: - PolishView

/// Multi-track Polish pane backed by an external cleanup service — Auphonic
/// (Multitrack API) or Cleanvoice — picked at the top of the pane.
///
/// Rendered inside `MaycastOperationShell`: the shell owns the back button,
/// title, status banner and the single primary action. This view only
/// supplies the content (API key, speakers, effects) and the state-driven
/// footer pieces.
///
/// One press of **Send to <service>** uploads every track in `tracks` as a
/// separate speaker file, lets the service run the chosen algorithms, then
/// downloads the per-speaker cleaned tracks and writes one new generation
/// per track.
struct PolishView: View {
    let episodeID: String
    let tracks: [PolishTrackSummary]
    /// Key state of the **selected** service.
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
            subtitle: "Clean up every track via \(provider.displayName)",
            onBack: { onBack?() },
            accessory: { headerChips },
            content: { content },
            status: { statusSection },
            leading: { resetButton },
            trailing: { trailingActions }
        )
    }

    private var provider: PolishProvider { settings.provider }

    private var hasVideo: Bool { tracks.contains(where: \.hasVideo) }

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
                    serviceSection
                    apiKeyBanner
                    speakersSection
                    switch provider {
                    case .auphonic: auphonicSections
                    case .cleanvoice: cleanvoiceSections
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: service

    private var serviceSection: some View {
        settingsGroup("Service") {
            MaycastSettingRow(icon: "server.rack", "Cleanup service", hint: provider.tagline) {
                Picker("Cleanup service", selection: $settings.provider) {
                    ForEach(PolishProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(status.isActive)
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
                title: "\(provider.displayName) API key",
                detail: "\(label) — runs consume your \(provider.displayName) account's credits."
            ) {
                Button("Change…") { onConfigureAPIKey?() }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            }
        case .missing:
            MaycastStatusBanner(
                tone: .warning,
                icon: "key.slash",
                title: "\(provider.displayName) API key not set",
                detail: "Issue one at \(provider.apiKeyService.helpURL) — it is stored in your Keychain."
            ) {
                Button("Configure…") { onConfigureAPIKey?() }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            }
        }
    }

    // MARK: speakers

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Speakers", trailing: provider == .auphonic ? "uploaded as one multitrack production" : "uploaded as one multitrack edit")
            MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                VStack(spacing: 8) {
                    ForEach(tracks) { track in
                        MaycastTrackRow(id: track.id, path: track.currentPath, duration: track.duration)
                    }
                }
            }
        }
    }

    // MARK: effects — Auphonic

    private var auphonicSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Loudness") {
                MaycastSettingRow(icon: "speaker.wave.2", "Loudness target", hint: "Integrated loudness of every cleaned track", layout: .stacked) {
                    HStack(spacing: 12) {
                        Slider(value: $settings.auphonic.loudnessTarget, in: -23 ... -14, step: 0.5)
                        MaycastValueLabel(String(format: "%.1f LUFS", settings.auphonic.loudnessTarget))
                    }
                }
                MaycastHairline()
                MaycastSettingRow(icon: "slider.horizontal.3", "Adaptive Leveler", hint: "Balances loudness across speakers") {
                    toggle($settings.auphonic.levelerEnabled)
                }
            }

            settingsGroup("Cleanup") {
                MaycastSettingRow(icon: "wand.and.sparkles", "Denoise") {
                    toggle($settings.auphonic.denoiseEnabled)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "list.bullet", "Denoise method", enabled: settings.auphonic.denoiseEnabled) {
                    Picker("Denoise method", selection: $settings.auphonic.denoiseMethod) {
                        ForEach(AuphonicPolishOptions.DenoiseMethod.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "wind", "Debreath", hint: "Attenuates breaths and sniffles") {
                    Picker("Debreath amount", selection: $settings.auphonic.debreathAmount) {
                        ForEach(AuphonicPolishOptions.DebreathAmount.allCases, id: \.self) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "waveform.path", "High-pass filter", hint: "Removes low-frequency rumble") {
                    toggle($settings.auphonic.hipfilterEnabled)
                }
            }

            settingsGroup("Cuts") {
                MaycastSettingRow(icon: "scissors", "Filler word cutter", hint: "え, あの, …") {
                    toggle($settings.auphonic.fillerCutterEnabled)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "scissors", "Silence cutter") {
                    toggle($settings.auphonic.silenceCutterEnabled)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "scissors", "Cough cutter") {
                    toggle($settings.auphonic.coughCutterEnabled)
                }
            }

            settingsGroup("Advanced") {
                MaycastSettingRow(icon: "tray.full", "Keep production on Auphonic dashboard", hint: "For debugging — costs storage on your account") {
                    toggle($settings.auphonic.keepProduction)
                }
            }
        }
    }

    // MARK: effects — Cleanvoice

    private var cleanvoiceSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsGroup("Loudness") {
                MaycastSettingRow(icon: "slider.horizontal.3", "Normalize", hint: "Levels every track to the target loudness") {
                    toggle($settings.cleanvoice.normalize)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "speaker.wave.2", "Loudness target", layout: .stacked, enabled: settings.cleanvoice.normalize) {
                    HStack(spacing: 12) {
                        Slider(value: $settings.cleanvoice.targetLufs, in: -23 ... -14, step: 0.5)
                        MaycastValueLabel(String(format: "%.1f LUFS", settings.cleanvoice.targetLufs))
                    }
                }
            }

            settingsGroup("Enhance") {
                MaycastSettingRow(icon: "wand.and.sparkles", "Remove noise") {
                    toggle($settings.cleanvoice.removeNoise)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "music.mic", "Studio sound", hint: "Aggressive enhancement — best for voice-only, quiet rooms") {
                    toggle($settings.cleanvoice.studioSound)
                }
            }

            settingsGroup("Remove") {
                MaycastSettingRow(icon: "scissors", "Filler words", hint: "え, あの, um, uh, …") {
                    toggle($settings.cleanvoice.fillers)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "scissors", "Long silences") {
                    toggle($settings.cleanvoice.longSilences)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "scissors", "Stutters") {
                    toggle($settings.cleanvoice.stutters)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "scissors", "Hesitations") {
                    toggle($settings.cleanvoice.hesitations)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "mouth", "Mouth sounds", hint: "Clicks, lip smacks") {
                    toggle($settings.cleanvoice.mouthSounds)
                }
                MaycastHairline()
                MaycastSettingRow(icon: "wind", "Breaths") {
                    Picker("Breath removal", selection: $settings.cleanvoice.breath) {
                        ForEach(CleanvoicePolishOptions.Breath.allCases, id: \.self) { b in
                            Text(b.label).tag(b)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                MaycastHairline()
                MaycastSettingRow(
                    icon: "speaker.slash",
                    "Mute instead of cut",
                    hint: hasVideo && !settings.cleanvoice.muteEdits
                        ? "Off: video tracks are cut at the same points as the audio"
                        : "Silences removed sounds, keeping the original timing"
                ) {
                    toggle($settings.cleanvoice.muteEdits)
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
                title: "Set a \(provider.displayName) API key to continue."
            )
        case .uploading(let progress):
            VStack(spacing: 8) {
                MaycastStatusBanner(tone: .info, title: "Uploading to \(provider.displayName)…", spinning: true)
                MaycastProgressRows(rows: progressRows(progress), tone: .info)
            }
        case .processing(let label):
            MaycastStatusBanner(
                tone: .progress,
                title: "\(provider.displayName) processing",
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
        Button("Reset to defaults") { settings.resetProviderOptions() }
            .buttonStyle(MaycastGhostButtonStyle())
            .disabled(settings.isAtProviderDefaults || status.isActive)
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
        default: return "Send to \(provider.displayName)"
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

private let polishSampleVideoTracks: [PolishTrackSummary] = [
    PolishTrackSummary(id: "host",  currentPath: Track.sampleHost.current,  duration: 1820.5, hasVideo: true),
    PolishTrackSummary(id: "guest", currentPath: Track.sampleGuest.current, duration: 1822.0, hasVideo: true),
]

private let polishCleanvoiceSettings: PolishSettings = {
    var s = PolishSettings.defaults
    s.provider = .cleanvoice
    return s
}()

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

#Preview("Cleanvoice — idle") {
    PolishPreviewHost(settings: polishCleanvoiceSettings, status: .idle)
}

#Preview("Cleanvoice — needs API key") {
    PolishPreviewHost(settings: polishCleanvoiceSettings, status: .needsApiKey, apiKeyStatus: .missing)
}

#Preview("Cleanvoice — video episode (cuts follow)") {
    PolishPreviewHost(settings: polishCleanvoiceSettings, status: .idle, tracks: polishSampleVideoTracks)
}

#Preview("Cleanvoice — processing") {
    PolishPreviewHost(settings: polishCleanvoiceSettings, status: .processing(statusString: "EDITING · Removing fillers 3/7"))
}

#Preview("Cleanvoice — failed") {
    PolishPreviewHost(settings: polishCleanvoiceSettings, status: .failed(message: "Cleanvoice API: HTTP 401 — Invalid API key"))
}

#Preview("Empty — no tracks") {
    PolishPreviewHost(status: .idle, tracks: [])
}

#Preview("Compact window") {
    PolishPreviewHost(status: .idle, size: CGSize(width: 720, height: 520))
}
#endif
