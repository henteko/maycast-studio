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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                .padding(20)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Episode History").font(.title2.bold())
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) { content() }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(batch.kind.capitalized)
                    .font(.callout.weight(.semibold))
                Text(batch.trackSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.timeFormatter.string(from: batch.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ForEach(batch.changes) { entry in
                HStack(spacing: 6) {
                    Text(entry.trackID)
                        .font(.caption.weight(.medium).monospaced())
                        .frame(width: 60, alignment: .leading)
                    Text(entry.from)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.to)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(10)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
        .opacity(style == .undone ? 0.55 : 1.0)
    }

    private var icon: String {
        switch batch.kind {
        case "slice": return "scissors"
        case "polish": return "wand.and.sparkles"
        case "mix": return "rectangle.stack"
        default: return "circle.fill"
        }
    }

    private var iconColor: Color {
        style == .applied ? .accentColor : .secondary
    }

    private var rowBackground: some ShapeStyle {
        style == .applied ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.background.tertiary)
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
