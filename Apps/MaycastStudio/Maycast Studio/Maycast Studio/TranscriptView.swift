import SwiftUI
import MaycastCore

// MARK: - Models

/// Per-track transcript state, displayed in the panel.
///
/// `.generating` carries any segments produced so far AND a human-readable
/// status ("Downloading model…", "Transcribing…", etc.) so the user can see
/// progress even on first run when the model is being downloaded.
enum TrackTranscriptState: Sendable, Equatable {
    case empty
    case generating(partialSegments: [TranscriptSegment], status: String?)
    case populated(segments: [TranscriptSegment])
    case failed(message: String)
}

struct TranscriptTrackInfo: Identifiable, Sendable {
    let id: String                       // trackID
    let state: TrackTranscriptState
}

/// One row in the chronological transcript list (= one phrase from one
/// speaker). Word-level segments from a single track are merged into phrases
/// using a short gap threshold.
struct TranscriptLine: Sendable, Identifiable, Equatable {
    let id: String                       // synthesised from trackID + start
    let trackID: String
    let start: Double
    let end: Double
    let text: String
}

// MARK: - TranscriptPanel

struct TranscriptPanel: View {
    let tracks: [TranscriptTrackInfo]
    let currentTime: Double
    var onTranscribeAll: (() -> Void)? = nil
    var onLineTap: ((TimeInterval) -> Void)? = nil
    var onClose: (() -> Void)? = nil

    private var lines: [TranscriptLine] {
        TranscriptPanel.makeLines(from: tracks)
    }

    private var statusLines: [(trackID: String, message: String, isError: Bool)] {
        tracks.compactMap { info in
            switch info.state {
            case .generating(_, let status):
                return (info.id, status ?? "Transcribing…", false)
            case .failed(let msg):
                return (info.id, msg, true)
            default:
                return nil
            }
        }
    }

    private var hasAnyEmpty: Bool {
        tracks.contains { if case .empty = $0.state { return true } else { return false } }
    }

    private var isAnyGenerating: Bool {
        tracks.contains { if case .generating = $0.state { return true } else { return false } }
    }

    private var hasAnyPopulated: Bool {
        tracks.contains { if case .populated = $0.state { return true } else { return false } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !statusLines.isEmpty {
                statusBanner
            }
            Divider()
            if lines.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            TranscriptLineRow(
                                line: line,
                                speakerColor: TranscriptPanel.speakerColor(for: line.trackID),
                                isCurrent: currentTime >= line.start && currentTime < line.end,
                                onTap: { onLineTap?(line.start) }
                            )
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .background(.background.tertiary)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Transcript", systemImage: "text.quote")
                .font(.callout.weight(.semibold))
            Spacer()
            // The transcribe button is always visible (unless a run is in
            // progress) so users can re-run on populated tracks too.
            if !isAnyGenerating {
                Button(action: { onTranscribeAll?() }) {
                    Label(transcribeButtonLabel,
                          systemImage: hasAnyPopulated && !hasAnyEmpty
                            ? "arrow.clockwise" : "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(tracks.isEmpty)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Hide panel")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcribeButtonLabel: String {
        if hasAnyEmpty && hasAnyPopulated { return "Transcribe / Re-transcribe all" }
        if hasAnyEmpty { return "Transcribe all" }
        if hasAnyPopulated { return "Re-transcribe all" }
        return "Transcribe all"
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(statusLines, id: \.trackID) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.isError ? "exclamationmark.triangle.fill" : "waveform.badge.magnifyingglass")
                        .foregroundStyle(item.isError ? .red : .secondary)
                    Text(item.trackID)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TranscriptPanel.speakerColor(for: item.trackID))
                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.background.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No transcripts yet")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Click \"Transcribe all\" to generate.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    /// Group word-level segments into phrase-level lines per track, then merge
    /// across tracks and sort by start time. Includes partial segments from
    /// `.generating` so the user sees lines appear as transcription progresses.
    static func makeLines(from tracks: [TranscriptTrackInfo], maxGap: Double = 0.6) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        for info in tracks {
            let allSegs: [TranscriptSegment]
            switch info.state {
            case .populated(let s): allSegs = s
            case .generating(let p, _): allSegs = p
            default: continue
            }
            guard !allSegs.isEmpty else { continue }
            let sorted = allSegs.sorted { $0.start < $1.start }
            var current: (start: Double, end: Double, text: String)? = nil
            for s in sorted {
                if var cur = current, s.start - cur.end <= maxGap {
                    cur.text += joiner(prev: cur.text, next: s.text) + s.text
                    cur.end = s.end
                    current = cur
                } else {
                    if let cur = current {
                        out.append(TranscriptLine(
                            id: "\(info.id)-\(cur.start)",
                            trackID: info.id, start: cur.start, end: cur.end, text: cur.text
                        ))
                    }
                    current = (s.start, s.end, s.text)
                }
            }
            if let cur = current {
                out.append(TranscriptLine(
                    id: "\(info.id)-\(cur.start)",
                    trackID: info.id, start: cur.start, end: cur.end, text: cur.text
                ))
            }
        }
        out.sort { $0.start < $1.start }
        return out
    }

    /// Decide whether to insert a space between two adjacent tokens.
    private static func joiner(prev: String, next: String) -> String {
        if prev.isEmpty { return "" }
        if next.hasPrefix(",") || next.hasPrefix(".") || next.hasPrefix("!") || next.hasPrefix("?")
            || next.hasPrefix("、") || next.hasPrefix("。") { return "" }
        // Japanese characters typically don't need spaces.
        if let last = prev.last, last.isJapanese, let first = next.first, first.isJapanese { return "" }
        return " "
    }

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
    static func speakerColor(for trackID: String) -> Color {
        var hash = 0
        for c in trackID.unicodeScalars { hash = hash &+ Int(c.value) }
        return palette[abs(hash) % palette.count]
    }
}

private extension Character {
    /// Treat anything outside the basic Latin range as "Japanese-ish" — good
    /// enough for the spacing heuristic used to join word segments.
    var isJapanese: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.value > 0x7F
    }
}

// MARK: - TranscriptLineRow

private struct TranscriptLineRow: View {
    let line: TranscriptLine
    let speakerColor: Color
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatTime(line.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)
            SpeakerBadge(name: line.trackID, color: speakerColor)
            Text(line.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func formatTime(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct SpeakerBadge: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

// MARK: - Preview samples

#if DEBUG
private let sampleHostSegments: [TranscriptSegment] = [
    TranscriptSegment(start: 0.0, end: 0.4, text: "It"),
    TranscriptSegment(start: 0.4, end: 0.7, text: "was"),
    TranscriptSegment(start: 0.7, end: 0.9, text: "a"),
    TranscriptSegment(start: 0.9, end: 1.4, text: "dark"),
    TranscriptSegment(start: 1.4, end: 1.7, text: "and"),
    TranscriptSegment(start: 1.7, end: 2.4, text: "stormy"),
    TranscriptSegment(start: 2.4, end: 3.0, text: "night."),
    TranscriptSegment(start: 4.0, end: 4.4, text: "The"),
    TranscriptSegment(start: 4.4, end: 4.9, text: "wind"),
    TranscriptSegment(start: 4.9, end: 5.5, text: "howled"),
    TranscriptSegment(start: 5.5, end: 5.8, text: "through"),
    TranscriptSegment(start: 5.8, end: 6.1, text: "the"),
    TranscriptSegment(start: 6.1, end: 6.8, text: "trees."),
]

private let sampleGuestSegments: [TranscriptSegment] = [
    TranscriptSegment(start: 3.2, end: 3.6, text: "Indeed,"),
    TranscriptSegment(start: 3.6, end: 3.9, text: "it"),
    TranscriptSegment(start: 3.9, end: 4.0, text: "was"),
    TranscriptSegment(start: 7.0, end: 7.8, text: "tempestuous"),
    TranscriptSegment(start: 7.8, end: 8.5, text: "weather"),
    TranscriptSegment(start: 8.5, end: 8.7, text: "indeed."),
]
#endif

#Preview("Populated (chronological merge)") {
    TranscriptPanel(
        tracks: [
            TranscriptTrackInfo(id: "host",  state: .populated(segments: sampleHostSegments)),
            TranscriptTrackInfo(id: "guest", state: .populated(segments: sampleGuestSegments)),
        ],
        currentTime: 1.8
    )
    .frame(width: 760, height: 280)
}

#Preview("Populated — Re-transcribe button visible") {
    TranscriptPanel(
        tracks: [
            TranscriptTrackInfo(id: "host",  state: .populated(segments: sampleHostSegments)),
            TranscriptTrackInfo(id: "guest", state: .populated(segments: sampleGuestSegments)),
        ],
        currentTime: 0,
        onTranscribeAll: { },
        onClose: { }
    )
    .frame(width: 760, height: 280)
}

#Preview("Mixed (host done, guest generating)") {
    TranscriptPanel(
        tracks: [
            TranscriptTrackInfo(id: "host",  state: .populated(segments: sampleHostSegments)),
            TranscriptTrackInfo(id: "guest", state: .generating(partialSegments: Array(sampleGuestSegments.prefix(3)), status: "Transcribing…")),
        ],
        currentTime: 4.5
    )
    .frame(width: 760, height: 280)
}

#Preview("Model downloading") {
    TranscriptPanel(
        tracks: [
            TranscriptTrackInfo(id: "host",  state: .generating(partialSegments: [], status: "Downloading speech model for ja-JP…")),
            TranscriptTrackInfo(id: "guest", state: .generating(partialSegments: [], status: "Pending…")),
        ],
        currentTime: 0
    )
    .frame(width: 760, height: 240)
}

#Preview("Empty") {
    TranscriptPanel(
        tracks: [
            TranscriptTrackInfo(id: "host",  state: .empty),
            TranscriptTrackInfo(id: "guest", state: .empty),
        ],
        currentTime: 0
    )
    .frame(width: 760, height: 240)
}

#Preview("Failed") {
    TranscriptPanel(
        tracks: [
            TranscriptTrackInfo(id: "host",
                state: .failed(message: "Speech Recognition permission not granted")),
            TranscriptTrackInfo(id: "guest", state: .empty),
        ],
        currentTime: 0
    )
    .frame(width: 760, height: 240)
}
