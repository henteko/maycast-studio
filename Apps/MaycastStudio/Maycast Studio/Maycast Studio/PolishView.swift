import SwiftUI
import MaycastCore

/// Summary of a track for display in the Polish panel.
struct PolishTrackSummary: Identifiable, Sendable {
    let id: String
    let currentPath: String
    let duration: TimeInterval
    let measuredLUFS: Double?
}

/// Per-track result of a polish run.
struct PolishTrackResult: Identifiable, Sendable, Equatable {
    let id: String
    let generationPath: String
    let measuredLUFS: Double?
}

enum PolishStatus: Sendable, Equatable {
    case idle
    case processing
    case completed(results: [PolishTrackResult])
    case failed(message: String)
}

struct PolishSettings: Equatable, Sendable {
    var loudnessEnabled: Bool
    var loudnessTarget: Double  // LUFS, range -23..-14
    var denoiseEnabled: Bool
    var deEsserEnabled: Bool

    static let defaults = PolishSettings(
        loudnessEnabled: true,
        loudnessTarget: -16,
        denoiseEnabled: false,
        deEsserEnabled: false
    )
}

/// Multi-track Polish panel. The same settings apply to every track in
/// `tracks` and `Apply` invokes the polish operation on each.
struct PolishView: View {
    let tracks: [PolishTrackSummary]
    @Binding var settings: PolishSettings
    @Binding var status: PolishStatus
    var onApply: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            tracksSection
            Divider()
            effectsSection
            Divider()
            statusSection
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 500)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Polish").font(.title2.bold())
            Spacer()
            Label("\(tracks.count) track\(tracks.count == 1 ? "" : "s")",
                  systemImage: "rectangle.stack")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Targets — settings below apply to all tracks").font(.headline)
            ForEach(tracks) { track in
                HStack(spacing: 10) {
                    Image(systemName: "waveform").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.id).font(.body.weight(.medium))
                        Text(track.currentPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2fs", track.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let lufs = track.measuredLUFS {
                            Text(String(format: "%.1f LUFS", lufs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("— LUFS")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Loudness
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.loudnessEnabled) {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                        Text("Loudness normalization")
                    }
                }
                .toggleStyle(.switch)

                HStack {
                    Text("Target")
                        .frame(width: 50, alignment: .leading)
                        .foregroundStyle(settings.loudnessEnabled ? .primary : .secondary)
                    Slider(value: $settings.loudnessTarget, in: -23 ... -14, step: 0.5)
                        .disabled(!settings.loudnessEnabled)
                    Text(String(format: "%.1f LUFS", settings.loudnessTarget))
                        .frame(width: 90, alignment: .trailing)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(settings.loudnessEnabled ? .primary : .secondary)
                }
                Text("Each track is normalized to the target independently.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Denoise (placeholder)
            Toggle(isOn: $settings.denoiseEnabled) {
                HStack {
                    Image(systemName: "wand.and.sparkles")
                    Text("Denoise")
                    Text("(Phase 3)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .disabled(true)

            // De-esser (placeholder)
            Toggle(isOn: $settings.deEsserEnabled) {
                HStack {
                    Image(systemName: "waveform.path.ecg")
                    Text("De-esser")
                    Text("(Phase 3)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .disabled(true)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch status {
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Ready to polish").foregroundStyle(.secondary)
            }
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Polishing all tracks…")
            }
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

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: { onApply?() }) {
                if case .processing = status { Text("Polishing…") } else { Text("Apply to all") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(disableApply)
        }
    }

    private var disableApply: Bool {
        if case .processing = status { return true }
        if tracks.isEmpty { return true }
        return !(settings.loudnessEnabled || settings.denoiseEnabled || settings.deEsserEnabled)
    }
}

// MARK: - Previews

#if DEBUG
private let polishSampleTracks: [PolishTrackSummary] = [
    PolishTrackSummary(id: "host",  currentPath: "intermediate/host/003_polish.wav",  duration: 12.5, measuredLUFS: -22.4),
    PolishTrackSummary(id: "guest", currentPath: "intermediate/guest/001_import.wav", duration: 10.2, measuredLUFS: -18.7),
]

private struct PolishPreviewHost: View {
    @State var settings: PolishSettings = .defaults
    @State var status: PolishStatus = .idle
    let tracks: [PolishTrackSummary]

    var body: some View {
        PolishView(tracks: tracks, settings: $settings, status: $status)
    }
}
#endif

#Preview("Idle (2 tracks)") {
    PolishPreviewHost(tracks: polishSampleTracks)
}

#Preview("Processing") {
    PolishPreviewHost(status: .processing, tracks: polishSampleTracks)
}

#Preview("Completed") {
    PolishPreviewHost(
        status: .completed(results: [
            PolishTrackResult(id: "host",  generationPath: "intermediate/host/004_polish.wav",  measuredLUFS: -16.1),
            PolishTrackResult(id: "guest", generationPath: "intermediate/guest/002_polish.wav", measuredLUFS: -15.9),
        ]),
        tracks: polishSampleTracks
    )
}

#Preview("Failed") {
    PolishPreviewHost(
        status: .failed(message: "Loudness measurement requires 48kHz sample rate"),
        tracks: polishSampleTracks
    )
}
