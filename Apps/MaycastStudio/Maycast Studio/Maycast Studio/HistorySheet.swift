import SwiftUI
import MaycastCore

/// Sheet listing every recorded operation for the current episode, plus any
/// entries that are currently in the redo stack. Read-only — the user
/// changes state with the standard Undo / Redo commands.
struct HistorySheet: View {
    let bundle: EpisodeBundle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MaycastSheetShell(
            icon: "clock.arrow.circlepath",
            tone: .neutral,
            title: "Episode History",
            subtitle: "Every applied operation, newest first, plus any batches you can still redo with ⇧⌘Z.",
            width: 720,
            height: 560,
            content: { content },
            trailing: {
                Button("Close") { dismiss() }
                    .buttonStyle(MaycastSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        if operationBatches.isEmpty && undoneBatches.isEmpty {
            MaycastEmptyState(
                icon: "clock.arrow.circlepath",
                title: "No operations yet",
                message: "Slice, Polish, Chapters and Mix each record a batch here. Undo and Redo walk through them."
            )
        } else {
            VStack(alignment: .leading, spacing: 20) {
                section(
                    title: "Applied",
                    trailing: "newest first · \(operationBatches.count) \(operationBatches.count == 1 ? "batch" : "batches")"
                ) {
                    if operationBatches.isEmpty {
                        MaycastStatusBanner(tone: .idle, icon: "circle.dashed", title: "Nothing applied — every batch has been undone.")
                    } else {
                        ForEach(operationBatches) { batch in
                            HistoryBatchRow(batch: batch, style: .applied)
                        }
                    }
                }
                if !undoneBatches.isEmpty {
                    section(
                        title: "Available to redo",
                        trailing: "\(undoneBatches.count) \(undoneBatches.count == 1 ? "batch" : "batches")"
                    ) {
                        ForEach(undoneBatches) { batch in
                            HistoryBatchRow(batch: batch, style: .undone)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        trailing: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MaycastSectionLabel(title, trailing: trailing)
            VStack(spacing: 10) { content() }
        }
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
        MaycastCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MaycastIconTile(systemName: icon, size: 28, iconSize: 13, tone: tone, cornerRadius: MaycastRadius.inner)
                    Text(batch.kind.capitalized)
                        .font(MaycastFont.body(13.5, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text(batch.trackSummary)
                        .font(MaycastFont.mono(11.5))
                        .foregroundStyle(MaycastPalette.fg3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if style == .undone {
                        MaycastChip("undone", tone: .neutral) {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                        }
                    }
                    Spacer()
                    Text(Self.timeFormatter.string(from: batch.timestamp))
                        .font(MaycastFont.mono(11))
                        .foregroundStyle(MaycastPalette.fg3)
                }
                VStack(spacing: 6) {
                    ForEach(batch.changes) { entry in
                        HStack(spacing: 8) {
                            Text(entry.trackID)
                                .font(MaycastFont.mono(11.5, weight: .semibold))
                                .foregroundStyle(MaycastPalette.fg1)
                                .frame(width: 80, alignment: .leading)
                            Text(entry.from)
                                .font(MaycastFont.mono(11))
                                .foregroundStyle(MaycastPalette.fg3)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MaycastPalette.fg4)
                            Text(entry.to)
                                .font(MaycastFont.mono(11))
                                .foregroundStyle(MaycastPalette.mint700)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: MaycastRadius.inner, style: .continuous)
                        .fill(MaycastPalette.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MaycastRadius.inner, style: .continuous)
                        .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
                )
            }
        }
        .opacity(style == .undone ? 0.55 : 1.0)
    }

    private var icon: String {
        switch batch.kind {
        case "slice": return "scissors"
        case "polish": return "wand.and.stars"
        case "chapters": return "list.bullet.rectangle"
        case "mix": return "rectangle.stack"
        default: return "circle.fill"
        }
    }

    private var tone: MaycastChip<EmptyView>.Tone {
        switch batch.kind {
        case "slice": return .sky
        case "polish": return .mint
        case "chapters": return .sky
        case "mix": return .sun
        default: return .neutral
        }
    }
}

// MARK: - Previews

#if DEBUG
/// `EpisodeBundle.sampleWithTracks` (ContentView.swift) plus one undone
/// batch so the redo section renders.
private let historyPreviewBundle: EpisodeBundle = {
    var bundle = EpisodeBundle.sampleWithTracks
    bundle.episode.undone = [
        OperationLogEntry(
            batchID: UUID().uuidString, kind: "polish", trackID: "host",
            from: "intermediate/host/003_polish.wav", to: "intermediate/host/004_polish.wav",
            timestamp: Date().addingTimeInterval(-10)
        ),
    ]
    return bundle
}()

#Preview("History — applied + redo") {
    HistorySheet(bundle: historyPreviewBundle)
}

#Preview("History — applied only") {
    HistorySheet(bundle: EpisodeBundle.sampleWithTracks)
}

#Preview("History — empty") {
    HistorySheet(bundle: EpisodeBundle(
        url: URL(fileURLWithPath: "/tmp/empty.maycast"),
        episode: Episode(id: "empty")
    ))
}
#endif
