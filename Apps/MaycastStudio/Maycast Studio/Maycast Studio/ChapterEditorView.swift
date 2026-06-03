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

/// State of the "generate chapters from transcript" run. Generation runs in
/// the cloud via Google's Gemini API (requires an API key).
enum ChapterGenerationState: Sendable, Equatable {
    case idle
    case generating                       // Gemini is producing chapters
    case failed(message: String)
}

/// State of transcribing the episode's tracks, offered inline when no
/// transcript exists yet (chapters are derived from the transcript).
enum ChapterTranscribeState: Sendable, Equatable {
    case idle
    case running(status: String?)
    case failed(message: String)
}

/// Snapshot of the inline audio preview used to verify chapter boundaries.
///
/// The editor plays the **voice-timeline** mix (the same timeline chapter
/// `startSec` values live on), so seeking to a chapter's start lands exactly
/// where that chapter begins. Kept as a plain value type so previews can drive
/// the transport without an `AVAudioEngine`.
struct ChapterPreviewState: Sendable, Equatable {
    /// True once the episode audio has been loaded into the engine.
    var isReady: Bool = false
    var isPlaying: Bool = false
    /// Playhead position on the voice timeline, in seconds.
    var currentTime: Double = 0
    /// Total voice-timeline duration, in seconds.
    var totalDuration: Double = 0
    /// Set when audio failed to load (shown in place of the scrubber).
    var loadError: String? = nil
}

// MARK: - Chapter editor

/// Chapter editor sheet. Generates chapter markers from the episode transcript
/// via Google's Gemini API, then lets the user nudge times / titles, add and
/// remove rows before they get embedded into the MP3 on the next Mix.
struct ChapterEditorView: View {
    @Binding var chapters: [ChapterDraft]
    var generation: ChapterGenerationState = .idle
    /// State of an inline transcription run (offered when no transcript exists).
    var transcribe: ChapterTranscribeState = .idle
    /// Display name of the generator (informational chip only).
    var modelName: String = "Gemini 3.5 Flash"
    /// Whether the episode has a transcript to generate from. When false the
    /// editor offers a Transcribe action instead of disabling generation outright.
    var hasTranscript: Bool = true
    /// Whether a Gemini API key is configured. When false the editor disables
    /// generation and the key row reads "not set".
    var apiKeyConfigured: Bool = true
    /// Masked label for the configured key, e.g. "configured (••••2f1a)".
    /// Shown in the always-visible key row so the user can change it any time.
    var apiKeyLabel: String? = nil
    /// Inline audio preview state (transport bar + active-row highlight).
    var preview: ChapterPreviewState = ChapterPreviewState()

    var onGenerate: (() -> Void)? = nil
    /// Run transcription on every track, then chapters can be generated.
    var onTranscribe: (() -> Void)? = nil
    var onAddChapter: (() -> Void)? = nil
    var onDelete: ((ChapterDraft.ID) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    /// Present the Gemini API key settings sheet.
    var onConfigureKey: (() -> Void)? = nil
    /// Toggle play/pause of the preview from the current playhead.
    var onTogglePlay: (() -> Void)? = nil
    /// Seek the preview playhead to an absolute voice-timeline position.
    var onSeek: ((Double) -> Void)? = nil
    /// Seek to a chapter's start and start playing from there.
    var onPlayChapter: ((ChapterDraft) -> Void)? = nil

    /// Local scrub position while the user drags the transport slider. The seek
    /// is committed (via `onSeek`) only when the drag ends, so the engine isn't
    /// stopped/restarted on every intermediate value.
    @State private var scrubbing: Double? = nil

    private var isTranscribing: Bool {
        if case .running = transcribe { return true }
        return false
    }

    private var isBusy: Bool {
        if case .generating = generation { return true }
        return isTranscribing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pinned header + generation controls.
            VStack(alignment: .leading, spacing: 14) {
                header
                generationSection
                if !chapters.isEmpty {
                    transportBar
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // Scrollable chapter list — keeps the footer reachable no matter
            // how many chapters there are.
            ScrollView {
                chaptersSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                Text("Chapter markers are generated from the transcript and embedded into the final MP3. Edit times and titles below.")
                    .font(MaycastFont.body(12.5))
                    .foregroundStyle(MaycastPalette.fg2)
            }
        }
    }

    // MARK: - Transport (audio preview)

    /// Position shown by the transport + used to highlight the active row.
    /// While dragging the scrubber this reflects the in-flight scrub value.
    private var displayTime: Double { scrubbing ?? preview.currentTime }

    /// The chapter the playhead currently sits in — the last chapter whose
    /// start is at or before `displayTime`. Drives the row highlight + the
    /// title shown next to the transport time.
    private var activeChapterID: ChapterDraft.ID? {
        guard preview.isReady else { return nil }
        return chapters
            .filter { $0.startSec <= displayTime + 0.001 }
            .max(by: { $0.startSec < $1.startSec })?
            .id
    }

    private var activeChapterTitle: String? {
        guard let id = activeChapterID else { return nil }
        return chapters.first(where: { $0.id == id })?.title
    }

    private var transportBar: some View {
        MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14), cornerRadius: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button { onTogglePlay?() } label: {
                        Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(
                                Circle().fill(preview.isReady ? MaycastPalette.sky600 : MaycastPalette.fg4)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!preview.isReady)
                    .help(preview.isPlaying ? "Pause preview" : "Play preview")

                    Slider(
                        value: Binding(
                            get: { min(scrubbing ?? preview.currentTime, max(0.1, preview.totalDuration)) },
                            set: { scrubbing = $0 }
                        ),
                        in: 0...max(0.1, preview.totalDuration),
                        onEditingChanged: { editing in
                            if !editing, let v = scrubbing {
                                onSeek?(v)
                                scrubbing = nil
                            }
                        }
                    )
                    .controlSize(.small)
                    .tint(MaycastPalette.sky500)
                    .disabled(!preview.isReady)

                    Text("\(formatTimecode(displayTime)) / \(formatTimecode(preview.totalDuration))")
                        .font(MaycastFont.mono(11.5, weight: .semibold))
                        .foregroundStyle(MaycastPalette.fg1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }

                transportSubline
            }
        }
    }

    @ViewBuilder
    private var transportSubline: some View {
        if let message = preview.loadError {
            hintRow(icon: "exclamationmark.triangle.fill", text: message, tone: .danger)
        } else if !preview.isReady {
            hintRow(icon: "waveform", text: "Loading episode audio…", tone: .neutral)
        } else if let title = activeChapterTitle {
            HStack(spacing: 6) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(MaycastPalette.sky600)
                Text("Now playing").font(MaycastFont.body(10.5, weight: .bold))
                    .tracking(0.6).textCase(.uppercase)
                    .foregroundStyle(MaycastPalette.fg4)
                Text(title.isEmpty ? "(untitled)" : title)
                    .font(MaycastFont.body(12))
                    .foregroundStyle(MaycastPalette.fg2)
                    .lineLimit(1)
                Spacer()
            }
        } else {
            hintRow(icon: "play.circle",
                    text: "Press play, or use ▶ on a row to hear where each chapter starts.",
                    tone: .neutral)
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
                    .disabled(isBusy || !hasTranscript || !apiKeyConfigured)
                }

                apiKeyRow
                generationStatus
            }
        }
    }

    /// Always-visible API key status, mirroring the Polish (Auphonic) panel:
    /// shows the masked key when configured with a "Change…" button, or a
    /// "not set" warning with "Configure…" when missing. The button always
    /// opens the Gemini settings sheet so the key can be replaced/removed.
    private var apiKeyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: apiKeyConfigured ? "key.fill" : "key.slash")
                .foregroundStyle(apiKeyConfigured ? MaycastPalette.sky600 : hintColor(.warning))
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                if apiKeyConfigured {
                    Text("Gemini API key")
                        .font(MaycastFont.body(12, weight: .semibold))
                        .foregroundStyle(MaycastPalette.sky800)
                    if let apiKeyLabel {
                        Text(apiKeyLabel)
                            .font(MaycastFont.mono(10.5))
                            .foregroundStyle(MaycastPalette.sky700)
                    }
                } else {
                    Text("Gemini API key not set")
                        .font(MaycastFont.body(12, weight: .semibold))
                        .foregroundStyle(hintColor(.warning))
                    Text("Required to generate chapters. Get one from Google AI Studio.")
                        .font(MaycastFont.body(11))
                        .foregroundStyle(hintColor(.warning))
                }
            }
            Spacer()
            Button(apiKeyConfigured ? "Change…" : "Configure…") {
                onConfigureKey?()
            }
            .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(apiKeyConfigured ? MaycastPalette.sky50 : MaycastPalette.warning.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(apiKeyConfigured ? MaycastPalette.sky200 : MaycastPalette.warning.opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var generationStatus: some View {
        // Transcription (offered when there's no transcript yet) takes
        // precedence in the status area — you must transcribe before generating.
        switch transcribe {
        case .running(let status):
            hintRow(icon: nil, text: status ?? "Transcribing…", tone: .progress, spinning: true)
        case .failed(let message):
            errorBlock(title: "Transcription failed", message: message)
        case .idle:
            if !hasTranscript {
                noTranscriptRow
            } else {
                generationStatusForTranscript
            }
        }
    }

    @ViewBuilder
    private var generationStatusForTranscript: some View {
        switch generation {
        case .idle:
            if chapters.isEmpty {
                hintRow(icon: "info.circle",
                        text: "No chapters yet. Generate a first draft, then fine-tune the rows.",
                        tone: .neutral)
            }
        case .generating:
            hintRow(icon: nil, text: "Generating chapters…", tone: .progress, spinning: true)
        case .failed(let message):
            errorBlock(title: "Generation failed", message: message)
        }
    }

    /// No transcript yet: explain the prerequisite and offer to transcribe now.
    private var noTranscriptRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(hintColor(.warning))
            Text("Chapters are derived from the transcript. Transcribe the tracks first.")
                .font(MaycastFont.body(12))
                .foregroundStyle(hintColor(.warning))
            Spacer()
            Button { onTranscribe?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.system(size: 12))
                    Text("Transcribe")
                }
            }
            .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
            .disabled(isBusy)
        }
    }

    private func errorBlock(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            hintRow(icon: "exclamationmark.triangle.fill", text: title, tone: .danger)
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
                            ChapterRow(
                                chapter: $chapter,
                                isActive: chapter.id == activeChapterID,
                                isPlaying: preview.isPlaying && chapter.id == activeChapterID,
                                canPlay: preview.isReady,
                                onPlay: { onPlayChapter?(chapter) },
                                onDelete: { onDelete?(chapter.id) }
                            )
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
            Text("Embedded into the MP3 on the next Mix")
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
    /// The playhead currently sits inside this chapter.
    var isActive: Bool = false
    /// Active *and* the transport is playing (drives the ▸ pulse / icon).
    var isPlaying: Bool = false
    /// Audio is loaded, so the per-row play affordance is usable.
    var canPlay: Bool = false
    var onPlay: () -> Void = {}
    var onDelete: () -> Void

    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Play from this chapter's start. When this is the row the playhead
            // is in, it reads as the "active" marker too.
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isActive ? Color.white : MaycastPalette.sky600)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(isActive ? MaycastPalette.sky600 : MaycastPalette.sky100)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            .opacity(canPlay ? 1 : 0.4)
            .help("Play from here")

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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? MaycastPalette.sky50 : Color.clear)
        )
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
    var transcribe: ChapterTranscribeState = .idle
    var hasTranscript: Bool = true
    var apiKeyConfigured: Bool = true
    var apiKeyLabel: String? = "configured (••••2f1a)"
    @State var preview: ChapterPreviewState = ChapterPreviewState()

    var body: some View {
        ChapterEditorView(
            chapters: $chapters,
            generation: generation,
            transcribe: transcribe,
            hasTranscript: hasTranscript,
            apiKeyConfigured: apiKeyConfigured,
            apiKeyLabel: apiKeyConfigured ? apiKeyLabel : nil,
            preview: preview,
            onDelete: { id in chapters.removeAll { $0.id == id } },
            onClose: {},
            onDone: {},
            onTogglePlay: { preview.isPlaying.toggle() },
            onSeek: { preview.currentTime = $0 },
            onPlayChapter: { ch in
                preview.currentTime = ch.startSec
                preview.isPlaying = true
            }
        )
    }
}

#Preview("Normal (with chapters)") {
    ChapterEditorPreviewHost(
        chapters: chapterSamples,
        preview: ChapterPreviewState(isReady: true, isPlaying: false, currentTime: 0, totalDuration: 2400)
    )
}

#Preview("Playing (chapter 2 active)") {
    ChapterEditorPreviewHost(
        chapters: chapterSamples,
        preview: ChapterPreviewState(isReady: true, isPlaying: true, currentTime: 120, totalDuration: 2400)
    )
}

#Preview("Audio loading") {
    ChapterEditorPreviewHost(
        chapters: chapterSamples,
        preview: ChapterPreviewState(isReady: false, totalDuration: 0)
    )
}

#Preview("Audio load failed") {
    ChapterEditorPreviewHost(
        chapters: chapterSamples,
        preview: ChapterPreviewState(isReady: false, loadError: "Failed to load tracks: file not found")
    )
}

#Preview("Empty (no chapters)") {
    ChapterEditorPreviewHost(chapters: [])
}

#Preview("No transcript (can transcribe)") {
    ChapterEditorPreviewHost(chapters: [], hasTranscript: false)
}

#Preview("No API key (can configure)") {
    ChapterEditorPreviewHost(chapters: [], apiKeyConfigured: false)
}

#Preview("API key set (can change)") {
    ChapterEditorPreviewHost(chapters: chapterSamples, apiKeyConfigured: true)
}

#Preview("Transcribing") {
    ChapterEditorPreviewHost(
        chapters: [],
        transcribe: .running(status: "Transcribing host…"),
        hasTranscript: false
    )
}

#Preview("Generating") {
    ChapterEditorPreviewHost(chapters: chapterSamples, generation: .generating)
}

#Preview("Generation failed") {
    ChapterEditorPreviewHost(
        chapters: [],
        generation: .failed(message: "Gemini API HTTP 401: API key not valid")
    )
}
#endif
