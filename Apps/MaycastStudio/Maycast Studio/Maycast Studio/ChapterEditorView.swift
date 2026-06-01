import SwiftUI
import MaycastCore

// MARK: - UI-facing models
//
// Like MixView, the chapter editor works against UI-local value types so the
// mockup / previews stay self-contained. These map 1:1 onto the future
// MaycastCore `Chapter` model (docs/chapters.md §3) when the editor is wired
// to a real EpisodeBundle.

/// One editable chapter row. `startSec` is in the **voice timeline** (the same
/// timeline as the transcript); the intro-lead shift onto the final mix
/// timeline happens at export time (docs/chapters.md §6).
struct ChapterDraft: Identifiable, Equatable, Sendable {
    let id: String
    var startSec: Double
    var title: String
    var source: ChapterSourceTag

    init(id: String = UUID().uuidString, startSec: Double, title: String, source: ChapterSourceTag) {
        self.id = id
        self.startSec = startSec
        self.title = title
        self.source = source
    }

    /// Build a draft from a persisted Core `Chapter`, preserving id and source.
    init(_ chapter: Chapter) {
        self.init(id: chapter.id, startSec: chapter.start, title: chapter.title, source: ChapterSourceTag(chapter.source))
    }

    /// Map back to a persisted Core `Chapter`.
    var asChapter: Chapter {
        Chapter(id: id, start: startSec, title: title, source: source.asChapterSource)
    }
}

/// Provenance of a chapter — drives the small badge on each row.
enum ChapterSourceTag: String, Sendable {
    case generated   // produced by the LLM, untouched
    case edited      // LLM output the user has since tweaked
    case manual      // added by hand

    init(_ source: ChapterSource) {
        switch source {
        case .generated: self = .generated
        case .edited:    self = .edited
        case .manual:    self = .manual
        }
    }

    var asChapterSource: ChapterSource {
        switch self {
        case .generated: return .generated
        case .edited:    return .edited
        case .manual:    return .manual
        }
    }

    var label: String {
        switch self {
        case .generated: return "AI"
        case .edited:    return "AI · edited"
        case .manual:    return "manual"
        }
    }

    var tone: MaycastChip<EmptyView>.Tone {
        switch self {
        case .generated: return .sky
        case .edited:    return .sun
        case .manual:    return .neutral
        }
    }
}

/// State of the "generate chapters from transcript" run. The first invocation
/// may download the Gemma model, hence the dedicated `loadingModel` phase.
enum ChapterGenerationState: Sendable, Equatable {
    case idle
    case loadingModel(progress: Double)   // 0.0..1.0 — first-run model download / load
    case generating                       // model loaded, LLM producing chapters
    case failed(message: String)
}

// MARK: - Chapter editor

/// Chapter editor sheet. Generates chapter markers from the episode transcript
/// via a local LLM (Gemma 4), then lets the user nudge times / titles, add and
/// remove rows before they get embedded into the M4A on the next Mix.
struct ChapterEditorView: View {
    @Binding var chapters: [ChapterDraft]
    var generation: ChapterGenerationState = .idle
    /// Display name of the local model (informational chip only).
    var modelName: String = "Gemma 4 E4B"
    /// Whether the episode has a transcript to generate from. When false the
    /// generate button is disabled and a hint explains the prerequisite.
    var hasTranscript: Bool = true

    var onGenerate: (() -> Void)? = nil
    var onAddChapter: (() -> Void)? = nil
    var onDelete: ((ChapterDraft.ID) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil

    private var isBusy: Bool {
        switch generation {
        case .loadingModel, .generating: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                generationSection
                chaptersSection
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
        .frame(minWidth: 620, minHeight: 660)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            MaycastIconTile(systemName: "list.bullet.rectangle", tone: .sky)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Chapters").font(MaycastFont.display(19, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                    Text("episode metadata").font(MaycastFont.body(12))
                        .foregroundStyle(MaycastPalette.fg3)
                    Spacer()
                    MaycastChip("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")", tone: .sky) {
                        Image(systemName: "list.number").font(.system(size: 10))
                    }
                }
                Text("Chapter markers are generated from the transcript and embedded into the final M4A. Edit times and titles below.")
                    .font(MaycastFont.body(12.5))
                    .foregroundStyle(MaycastPalette.fg2)
            }
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        MaycastCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16), cornerRadius: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(MaycastPalette.sky600)
                    Text("Generate from transcript")
                        .font(MaycastFont.body(12.5, weight: .bold))
                        .foregroundStyle(MaycastPalette.fg1)
                    MaycastChip(modelName, tone: .neutral) {
                        Image(systemName: "cpu").font(.system(size: 10))
                    }
                    Spacer()
                    Button { onGenerate?() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars").font(.system(size: 12))
                            Text(chapters.isEmpty ? "Generate" : "Regenerate")
                        }
                    }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    .disabled(isBusy || !hasTranscript)
                }

                generationStatus
            }
        }
    }

    @ViewBuilder
    private var generationStatus: some View {
        switch generation {
        case .idle:
            if !hasTranscript {
                hintRow(icon: "exclamationmark.circle",
                        text: "Transcribe at least one track first — chapters are derived from the transcript.",
                        tone: .warning)
            } else if chapters.isEmpty {
                hintRow(icon: "info.circle",
                        text: "No chapters yet. Generate a first draft, then fine-tune the rows.",
                        tone: .neutral)
            }
        case .loadingModel(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading \(modelName)… first run downloads the model")
                        .font(MaycastFont.body(12))
                        .foregroundStyle(MaycastPalette.fg2)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(MaycastFont.mono(11.5))
                        .foregroundStyle(MaycastPalette.fg3)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MaycastPalette.ink100)
                        Capsule().fill(MaycastPalette.sky500)
                            .frame(width: geo.size.width * CGFloat(progress))
                    }
                }
                .frame(height: 8)
            }
        case .generating:
            hintRow(icon: nil, text: "Generating chapters…", tone: .progress, spinning: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                hintRow(icon: "exclamationmark.triangle.fill", text: "Generation failed", tone: .danger)
                Text(message)
                    .font(MaycastFont.mono(11.5))
                    .foregroundStyle(MaycastPalette.danger)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(MaycastPalette.danger.opacity(0.08))
                    )
            }
        }
    }

    private enum HintTone { case neutral, progress, warning, danger }

    private func hintRow(icon: String?, text: String, tone: HintTone, spinning: Bool = false) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView().controlSize(.small).tint(hintColor(tone))
            } else if let icon {
                Image(systemName: icon).foregroundStyle(hintColor(tone))
            }
            Text(text)
                .font(MaycastFont.body(12))
                .foregroundStyle(hintColor(tone))
            Spacer()
        }
    }

    private func hintColor(_ tone: HintTone) -> Color {
        switch tone {
        case .neutral:  return MaycastPalette.fg3
        case .progress: return MaycastPalette.sky700
        case .warning:  return Color(hex: 0xC4760A)
        case .danger:   return MaycastPalette.danger
        }
    }

    // MARK: - Chapter list

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chapter list")
                    .font(MaycastFont.body(10.5, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(MaycastPalette.fg3)
                Spacer()
                Button { onAddChapter?() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Add chapter")
                    }
                }
                .buttonStyle(MaycastGhostButtonStyle(size: .small))
            }

            if chapters.isEmpty {
                emptyList
            } else {
                MaycastCard(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8), cornerRadius: 12) {
                    VStack(spacing: 0) {
                        listHeader
                        ForEach($chapters) { $chapter in
                            ChapterRow(chapter: $chapter, onDelete: { onDelete?(chapter.id) })
                            if chapter.id != chapters.last?.id {
                                Rectangle().fill(MaycastPalette.border1).frame(height: 0.5)
                            }
                        }
                    }
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            Text("START")
                .frame(width: 78, alignment: .leading)
            Text("TITLE")
            Spacer()
        }
        .font(MaycastFont.body(9.5, weight: .bold))
        .tracking(1)
        .foregroundStyle(MaycastPalette.fg4)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var emptyList: some View {
        VStack(spacing: 10) {
            MaycastIconTile(systemName: "list.bullet.rectangle", size: 48, iconSize: 22, tone: .sky)
            Text("No chapters yet")
                .font(MaycastFont.display(16, weight: .bold))
                .foregroundStyle(MaycastPalette.fg1)
            Text("Generate a draft from the transcript, or add chapters by hand.")
                .font(MaycastFont.body(12.5))
                .foregroundStyle(MaycastPalette.fg2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MaycastPalette.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let onClose {
                Button("Cancel") { onClose() }
                    .buttonStyle(MaycastSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Text("Embedded into the M4A on the next Mix")
                .font(MaycastFont.body(11))
                .foregroundStyle(MaycastPalette.fg3)
            Button("Done") { onDone?() }
                .buttonStyle(MaycastPrimaryButtonStyle(glow: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Row

private struct ChapterRow: View {
    @Binding var chapter: ChapterDraft
    var onDelete: () -> Void

    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(MaycastPalette.fg4)

            // Start time — editable as mm:ss(.s)
            TextField("0:00", text: timecodeBinding)
                .textFieldStyle(.plain)
                .font(MaycastFont.mono(12, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
                .frame(width: 70)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MaycastPalette.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(MaycastPalette.border1, lineWidth: 0.5)
                )

            // Title — editable
            TextField("Chapter title", text: $chapter.title)
                .textFieldStyle(.plain)
                .font(MaycastFont.body(13))
                .foregroundStyle(MaycastPalette.fg1)
                .focused($titleFocused)
                .onChange(of: chapter.title) { _, _ in
                    // A hand-edit promotes an AI chapter to "edited".
                    if chapter.source == .generated { chapter.source = .edited }
                }

            MaycastChip(chapter.source.label, tone: chapter.source.tone)

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MaycastPalette.fg3)
            }
            .buttonStyle(.plain)
            .help("Remove chapter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var timecodeBinding: Binding<String> {
        Binding(
            get: { formatTimecode(chapter.startSec) },
            set: { if let v = parseTimecode($0) { chapter.startSec = v } }
        )
    }
}

// MARK: - Timecode helpers

/// Format seconds as `m:ss` (or `m:ss.s` when there's a fractional part).
func formatTimecode(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let secs = total - Double(minutes * 60)
    if secs.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%d:%02d", minutes, Int(secs))
    }
    return String(format: "%d:%04.1f", minutes, secs)
}

/// Parse `m:ss(.s)` or a bare seconds value back into seconds.
func parseTimecode(_ string: String) -> Double? {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    let parts = trimmed.split(separator: ":")
    switch parts.count {
    case 1:
        return Double(parts[0])
    case 2:
        guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    default:
        return nil
    }
}

// MARK: - Previews

#if DEBUG
private let chapterSamples: [ChapterDraft] = [
    ChapterDraft(startSec: 0,     title: "オープニング",          source: .generated),
    ChapterDraft(startSec: 92.4,  title: "今週のニュース",        source: .edited),
    ChapterDraft(startSec: 540,   title: "ゲストトーク：自己紹介", source: .generated),
    ChapterDraft(startSec: 1284,  title: "おたよりコーナー",       source: .manual),
    ChapterDraft(startSec: 1980,  title: "エンディング",          source: .generated),
]

private struct ChapterEditorPreviewHost: View {
    @State var chapters: [ChapterDraft]
    var generation: ChapterGenerationState = .idle
    var hasTranscript: Bool = true

    var body: some View {
        ChapterEditorView(
            chapters: $chapters,
            generation: generation,
            hasTranscript: hasTranscript,
            onDelete: { id in chapters.removeAll { $0.id == id } },
            onClose: {},
            onDone: {}
        )
    }
}

#Preview("Normal (with chapters)") {
    ChapterEditorPreviewHost(chapters: chapterSamples)
}

#Preview("Empty (no chapters)") {
    ChapterEditorPreviewHost(chapters: [])
}

#Preview("Empty (no transcript yet)") {
    ChapterEditorPreviewHost(chapters: [], hasTranscript: false)
}

#Preview("Loading model (first run)") {
    ChapterEditorPreviewHost(chapters: [], generation: .loadingModel(progress: 0.42))
}

#Preview("Generating") {
    ChapterEditorPreviewHost(chapters: chapterSamples, generation: .generating)
}

#Preview("Generation failed") {
    ChapterEditorPreviewHost(
        chapters: [],
        generation: .failed(message: "Model runtime error: failed to load gemma-4-e4b weights")
    )
}
#endif
