import SwiftUI
import MaycastCore

// MARK: - Models

/// Summary of a track for display in the Polish panel.
struct PolishTrackSummary: Identifiable, Sendable {
    let id: String
    let currentPath: String
    let duration: TimeInterval
    let measuredLUFS: Double?
}

/// Per-track result of a polish run. Generation path points at the cleaned
/// track that Auphonic returned (per-speaker, not the master mix).
struct PolishTrackResult: Identifiable, Sendable, Equatable {
    let id: String
    let generationPath: String
    let measuredLUFS: Double?
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
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            apiKeySection
            Divider()
            tracksSection
            Divider()
            ScrollView { effectsSection.padding(.trailing, 6) }
                .frame(maxHeight: 280)
            Divider()
            statusSection
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 620)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Polish").font(.title2.bold())
                Text("via Auphonic").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Label("\(tracks.count) track\(tracks.count == 1 ? "" : "s")",
                      systemImage: "rectangle.stack")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Cleans each track via the Auphonic Multitrack API and writes one new generation per speaker. Auphonic is a paid SaaS — running this consumes your account's processing time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: API key

    private var apiKeySection: some View {
        HStack(spacing: 10) {
            Image(systemName: apiKeyStatus == .missing ? "key.slash" : "key.fill")
                .foregroundStyle(apiKeyStatus == .missing ? .red : .green)
            VStack(alignment: .leading, spacing: 1) {
                switch apiKeyStatus {
                case .configured(let label):
                    Text("Auphonic API key").font(.callout.weight(.medium))
                    Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
                case .missing:
                    Text("Auphonic API key not set").font(.callout.weight(.medium))
                    Text("Configure one from https://auphonic.com/engine/account/")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(apiKeyStatus == .missing ? "Configure…" : "Change…") {
                onConfigureAPIKey?()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speakers — uploaded as multi-track to Auphonic").font(.headline)
            ForEach(tracks) { track in
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(.tint)
                    Text(track.id).font(.callout.weight(.medium))
                        .frame(width: 80, alignment: .leading)
                    Text(track.currentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let lufs = track.measuredLUFS {
                        Text(String(format: "%.1f LUFS", lufs))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(String(format: "%.1fs", track.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: effects

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Ready").foregroundStyle(.secondary)
            }
        case .needsApiKey:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Set an Auphonic API key to continue.")
            }
        case .uploading(let progress):
            statusBlock(label: "Uploading to Auphonic…",
                        icon: "arrow.up.circle",
                        perTrack: progress)
        case .processing(let label):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Auphonic processing — \(label.isEmpty ? "running" : label)")
            }
        case .downloading(let progress):
            statusBlock(label: "Downloading cleaned tracks…",
                        icon: "arrow.down.circle",
                        perTrack: progress)
        case .completed(let results):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Polish complete (\(results.count) track\(results.count == 1 ? "" : "s"))")
                        .font(.headline)
                }
                ForEach(results) { r in
                    HStack(spacing: 8) {
                        Text(r.id).font(.callout.weight(.medium)).frame(width: 80, alignment: .leading)
                        Text(r.generationPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let lufs = r.measuredLUFS {
                            Text(String(format: "%.1f LUFS", lufs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Polish failed").font(.headline)
                }
                Text(message)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusBlock(label: String, icon: String, perTrack: [String: Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(label).font(.headline)
            }
            ForEach(tracks) { track in
                HStack(spacing: 10) {
                    Text(track.id).font(.callout.weight(.medium)).frame(width: 80, alignment: .leading)
                    let value = perTrack[track.id] ?? 0
                    ProgressView(value: value)
                    Text("\(Int(value * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Spacer()
            if status.isActive {
                Button("Cancel") { onCancel?() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
            Button(action: { onApply?() }) {
                Text(applyLabel)
            }
            .buttonStyle(.borderedProminent)
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
    PolishTrackSummary(id: "host",  currentPath: "intermediate/host/003_polish.wav",  duration: 1820.5, measuredLUFS: -22.4),
    PolishTrackSummary(id: "guest", currentPath: "intermediate/guest/001_import.wav", duration: 1822.0, measuredLUFS: -18.7),
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
            PolishTrackResult(id: "host",  generationPath: "intermediate/host/004_polish.wav",  measuredLUFS: -16.1),
            PolishTrackResult(id: "guest", generationPath: "intermediate/guest/002_polish.wav", measuredLUFS: -15.9),
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
