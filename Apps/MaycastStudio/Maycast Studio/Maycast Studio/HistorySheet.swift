import SwiftUI
import MaycastCore

/// Sheet listing every recorded operation for the current episode, plus any
/// entries that are currently in the redo stack. Read-only — the user
/// changes state with the standard Undo / Redo commands.
struct HistorySheet: View {
    let bundle: EpisodeBundle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(title: "Applied", subtitle: "Newest first — \(operationBatches.count) batch(es)") {
                        if operationBatches.isEmpty {
                            emptyRow("No operations recorded yet.")
                        } else {
                            ForEach(operationBatches) { batch in
                                HistoryBatchRow(batch: batch, style: .applied)
                            }
                        }
                    }
                    if !undoneBatches.isEmpty {
                        section(title: "Available to redo", subtitle: "\(undoneBatches.count) batch(es)") {
                            ForEach(undoneBatches) { batch in
                                HistoryBatchRow(batch: batch, style: .undone)
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(MaycastPalette.bg1)
        .frame(minWidth: 720, minHeight: 540)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MaycastIconTile(systemName: "clock.arrow.circlepath", tone: .neutral)
            VStack(alignment: .leading, spacing: 2) {
                Text("Episode History")
                    .font(MaycastFont.display(19, weight: .bold))
                    .foregroundStyle(MaycastPalette.fg1)
                Text("Every applied operation, plus any entries you can still redo.")
                    .font(MaycastFont.body(12))
                    .foregroundStyle(MaycastPalette.fg3)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(MaycastSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(MaycastFont.body(13, weight: .bold))
                    .foregroundStyle(MaycastPalette.fg1)
                Text(subtitle)
                    .font(MaycastFont.body(11))
                    .foregroundStyle(MaycastPalette.fg3)
            }
            VStack(spacing: 10) { content() }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(MaycastFont.body(12.5))
            .foregroundStyle(MaycastPalette.fg3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MaycastPalette.bg2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
            )
    }

    // MARK: - Grouped data

    /// Operations grouped by batchID, newest batch first.
    private var operationBatches: [HistoryBatch] {
        groupByBatch(bundle.episode.operations).reversed()
    }

    /// Undone entries grouped by batchID, most recently undone first.
    private var undoneBatches: [HistoryBatch] {
        groupByBatch(bundle.episode.undone).reversed()
    }
}

// MARK: - HistoryBatch

struct HistoryBatch: Identifiable {
    let id: String  // batchID
    let kind: String
    let timestamp: Date
    var changes: [OperationLogEntry]

    var trackSummary: String {
        let unique = Array(NSOrderedSet(array: changes.map(\.trackID))) as? [String] ?? []
        return unique.joined(separator: ", ")
    }
}

func groupByBatch(_ entries: [OperationLogEntry]) -> [HistoryBatch] {
    var result: [HistoryBatch] = []
    for entry in entries {
        if !result.isEmpty, result[result.count - 1].id == entry.batchID {
            result[result.count - 1].changes.append(entry)
        } else {
            result.append(HistoryBatch(
                id: entry.batchID,
                kind: entry.kind,
                timestamp: entry.timestamp,
                changes: [entry]
            ))
        }
    }
    return result
}

// MARK: - Row

struct HistoryBatchRow: View {
    let batch: HistoryBatch
    let style: Style

    enum Style { case applied, undone }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        MaycastCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MaycastIconTile(systemName: icon, size: 30, iconSize: 13, tone: tone, cornerRadius: 8)
                    Text(batch.kind.capitalized)
                        .font(MaycastFont.body(13.5, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text(batch.trackSummary)
                        .font(MaycastFont.mono(11.5))
                        .foregroundStyle(MaycastPalette.fg3)
                    Spacer()
                    Text(Self.timeFormatter.string(from: batch.timestamp))
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.fg3)
                }
                VStack(spacing: 4) {
                    ForEach(batch.changes) { entry in
                        HStack(spacing: 6) {
                            Text(entry.trackID)
                                .font(MaycastFont.mono(11, weight: .bold))
                                .foregroundStyle(MaycastPalette.fg1)
                                .frame(width: 56, alignment: .leading)
                            Text(entry.from)
                                .font(MaycastFont.mono(11))
                                .foregroundStyle(MaycastPalette.fg3)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(MaycastPalette.fg4)
                            Text(entry.to)
                                .font(MaycastFont.mono(11))
                                .foregroundStyle(MaycastPalette.mint700)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MaycastPalette.bg2)
                )
            }
        }
        .opacity(style == .undone ? 0.55 : 1.0)
    }

    private var icon: String {
        switch batch.kind {
        case "slice": return "scissors"
        case "polish": return "wand.and.stars"
        case "mix": return "rectangle.stack"
        default: return "circle.fill"
        }
    }

    private var tone: MaycastChip<EmptyView>.Tone {
        switch batch.kind {
        case "slice": return .sky
        case "polish": return .mint
        case "mix": return .sun
        default: return .neutral
        }
    }
}

// MARK: - Previews

#if DEBUG
private let historyPreviewBundle: EpisodeBundle = {
    var episode = Episode(
        id: "ep01",
        tracks: [
            Track(id: "host", source: "sources/host.wav", current: "intermediate/host/003_polish.wav", history: []),
            Track(id: "guest", source: "sources/guest.wav", current: "intermediate/guest/003_polish.wav", history: []),
        ]
    )
    let now = Date()
    let sliceBatch = UUID().uuidString
    let polishBatch = UUID().uuidString
    episode.operations = [
        OperationLogEntry(
            batchID: sliceBatch, kind: "slice", trackID: "host",
            from: "intermediate/host/001_import.wav", to: "intermediate/host/002_slice.wav",
            timestamp: now.addingTimeInterval(-120)
        ),
        OperationLogEntry(
            batchID: sliceBatch, kind: "slice", trackID: "guest",
            from: "intermediate/guest/001_import.wav", to: "intermediate/guest/002_slice.wav",
            timestamp: now.addingTimeInterval(-120)
        ),
        OperationLogEntry(
            batchID: polishBatch, kind: "polish", trackID: "host",
            from: "intermediate/host/002_slice.wav", to: "intermediate/host/003_polish.wav",
            timestamp: now.addingTimeInterval(-30)
        ),
        OperationLogEntry(
            batchID: polishBatch, kind: "polish", trackID: "guest",
            from: "intermediate/guest/002_slice.wav", to: "intermediate/guest/003_polish.wav",
            timestamp: now.addingTimeInterval(-30)
        ),
    ]
    episode.undone = [
        OperationLogEntry(
            batchID: UUID().uuidString, kind: "polish", trackID: "host",
            from: "intermediate/host/003_polish.wav", to: "intermediate/host/004_polish.wav",
            timestamp: now.addingTimeInterval(-10)
        ),
    ]
    return EpisodeBundle(
        url: URL(fileURLWithPath: "/tmp/ep01.maycast"),
        episode: episode
    )
}()

#Preview("History (with redo)") {
    HistorySheet(bundle: historyPreviewBundle)
}

#Preview("History (empty)") {
    HistorySheet(bundle: EpisodeBundle(
        url: URL(fileURLWithPath: "/tmp/empty.maycast"),
        episode: Episode(id: "empty")
    ))
}
#endif
