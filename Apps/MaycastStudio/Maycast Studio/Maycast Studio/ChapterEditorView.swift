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

/// Chapter editor pane. Generates chapter markers from the episode transcript
/// via Google's Gemini API, then lets the user nudge times / titles, add and
/// remove rows before they get embedded into the MP3 on the next Mix.
///
/// Rendered inside `MaycastOperationShell`: the shell owns the back button,
/// title, footer status banner and the single primary action ("Done").
struct ChapterEditorView: View {
    let episodeID: String
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
    /// generation and the key banner reads "not set".
    var apiKeyConfigured: Bool = true
    /// Masked label for the configured key, e.g. "configured (••••2f1a)".
    var apiKeyLabel: String? = nil
    /// Inline audio preview state (transport bar + active-row highlight).
    var preview: ChapterPreviewState = ChapterPreviewState()

    var onGenerate: (() -> Void)? = nil
    /// Abort an in-flight generation run.
    var onCancelGeneration: (() -> Void)? = nil
    /// Run transcription on every track, then chapters can be generated.
    var onTranscribe: (() -> Void)? = nil
    var onAddChapter: (() -> Void)? = nil
    var onDelete: ((ChapterDraft.ID) -> Void)? = nil
    /// Return to the episode overview without saving (the shell's back button).
    var onBack: (() -> Void)? = nil
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

    private var isGenerating: Bool {
        if case .generating = generation { return true }
        return false
    }

    private var isBusy: Bool { isGenerating || isTranscribing }

    private var canGenerate: Bool { !isBusy && hasTranscript && apiKeyConfigured }

    var body: some View {
        MaycastOperationShell(
            episodeID: episodeID,
            icon: "list.bullet.rectangle",
            tone: .sky,
            title: "Chapters",
            subtitle: "Generate and fine-tune chapter markers",
            onBack: { onBack?() },
            accessory: { headerChips },
            content: { content },
            status: { statusSection },
            leading: { EmptyView() },
            trailing: { trailingActions }
        )
    }

    // MARK: - Header chips

    private var headerChips: some View {
        HStack(spacing: 6) {
            if !apiKeyConfigured {
                MaycastChip("API key missing", tone: .warning) {
                    Image(systemName: "key.slash").font(.system(size: 10))
                }
            }
            MaycastChip("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")", tone: .sky) {
                Image(systemName: "list.number").font(.system(size: 10))
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                apiKeyBanner
                generationSection
                if !chapters.isEmpty {
                    transportBar
                }
                chaptersSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - API key

    /// Always-visible API key status, mirroring the Polish (Auphonic) pane.
    /// The button always opens the Gemini settings sheet so the key can be
    /// replaced/removed.
    @ViewBuilder
    private var apiKeyBanner: some View {
        if apiKeyConfigured {
            MaycastStatusBanner(
                tone: .success,
                icon: "key.fill",
                title: "Gemini API key",
                detail: apiKeyLabel.map { "\($0) — generation runs in the cloud via Google AI." }
                    ?? "Generation runs in the cloud via Google AI."
            ) {
                Button("Change…") { onConfigureKey?() }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    .disabled(isBusy)
            }
        } else {
            MaycastStatusBanner(
                tone: .warning,
                icon: "key.slash",
                title: "Gemini API key not set",
                detail: "Required to generate chapters. Get one from Google AI Studio — it is stored in your Keychain."
            ) {
                Button("Configure…") { onConfigureKey?() }
                    .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                    .disabled(isBusy)
            }
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Generate", trailing: "from the transcript")
            MaycastCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MaycastPalette.sky600)
                        Text("Generate from transcript")
                            .font(MaycastFont.body(13, weight: .medium))
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
                        .disabled(!canGenerate)
                    }

                    if !hasTranscript, !isTranscribing {
                        MaycastStatusBanner(
                            tone: .warning,
                            icon: "text.bubble",
                            title: "No transcript yet",
                            detail: "Chapters are derived from the transcript. Transcribe the tracks first."
                        ) {
                            Button { onTranscribe?() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 12))
                                    Text("Transcribe")
                                }
                            }
                            .buttonStyle(MaycastSecondaryButtonStyle(size: .small))
                            .disabled(isBusy)
                        }
                    }
                }
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
        VStack(alignment: .leading, spacing: 8) {
            MaycastSectionLabel("Preview", trailing: "voice timeline")
            MaycastCard(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button { onTogglePlay?() } label: {
                            Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(MaycastIconButtonStyle(active: preview.isPlaying))
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
    }

    @ViewBuilder
    private var transportSubline: some View {
        if let message = preview.loadError {
            MaycastStatusBanner(
                tone: .danger, icon: "exclamationmark.triangle.fill",
                title: "Audio preview unavailable", detail: message
            )
        } else if !preview.isReady {
            transportHint(icon: "waveform", text: "Loading episode audio…")
        } else if let title = activeChapterTitle {
            HStack(spacing: 6) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(MaycastPalette.mint600)
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
            transportHint(icon: "play.circle", text: "Press play, or use ▶ on a row to hear where each chapter starts.")
        }
    }

    private func transportHint(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(MaycastPalette.fg3)
            Text(text)
                .font(MaycastFont.body(11.5))
                .foregroundStyle(MaycastPalette.fg3)
            Spacer()
        }
    }

    // MARK: - Chapter list

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MaycastSectionLabel("Chapter list", trailing: "embedded into the MP3 on the next Mix")
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
                MaycastCard(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) {
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
                                MaycastHairline()
                            }
                        }
                    }
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 24, height: 1)
            Text("START")
                .frame(width: 92, alignment: .leading)
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

    @ViewBuilder
    private var emptyList: some View {
        if canGenerate {
            MaycastEmptyState(
                icon: "list.bullet.rectangle",
                tone: .sky,
                title: "No chapters yet",
                message: "Generate a first draft from the transcript, then fine-tune the rows. You can also add chapters by hand."
            ) {
                Button { onGenerate?() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.system(size: 12))
                        Text("Generate with Gemini")
                    }
                }
                .buttonStyle(MaycastPrimaryButtonStyle())
            }
        } else {
            MaycastEmptyState(
                icon: "list.bullet.rectangle",
                tone: .sky,
                title: "No chapters yet",
                message: "Generate a draft from the transcript, or add chapters by hand."
            )
        }
    }

    // MARK: - Status (footer)

    @ViewBuilder
    private var statusSection: some View {
        switch transcribe {
        case .running(let status):
            MaycastStatusBanner(
                tone: .progress,
                title: "Transcribing tracks…",
                detail: status,
                spinning: true
            )
        case .failed(let message):
            MaycastStatusBanner(
                tone: .danger, icon: "exclamationmark.triangle.fill",
                title: "Transcription failed", detail: message
            )
        case .idle:
            switch generation {
            case .generating:
                MaycastStatusBanner(
                    tone: .progress,
                    title: "Generating chapters with \(modelName)…",
                    detail: "Reading the transcript and proposing chapter boundaries.",
                    spinning: true
                )
            case .failed(let message):
                MaycastStatusBanner(
                    tone: .danger, icon: "exclamationmark.triangle.fill",
                    title: "Generation failed", detail: message
                )
            case .idle:
                if !apiKeyConfigured {
                    MaycastStatusBanner(
                        tone: .warning, icon: "exclamationmark.triangle.fill",
                        title: "Set a Gemini API key to generate chapters.",
                        detail: "You can still add and edit chapters by hand."
                    )
                } else if chapters.isEmpty {
                    MaycastStatusBanner(
                        tone: .idle, icon: "circle.dashed",
                        title: "No chapters yet",
                        detail: "Generate a first draft or add chapters by hand."
                    )
                } else {
                    MaycastStatusBanner(
                        tone: .idle, icon: "circle.dashed",
                        title: "\(chapters.count) chapter\(chapters.count == 1 ? "" : "s") ready",
                        detail: "Embedded into the MP3 on the next Mix."
                    )
                }
            }
        }
    }

    // MARK: - Footer actions

    @ViewBuilder
    private var trailingActions: some View {
        if isGenerating {
            Button("Cancel") { onCancelGeneration?() }
                .buttonStyle(MaycastDestructiveButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        Button("Done") { onDone?() }
            .buttonStyle(MaycastPrimaryButtonStyle(glow: !isBusy))
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
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
    @FocusState private var timecodeFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Play from this chapter's start. When this is the row the playhead
            // is in, it reads as the "active" marker too.
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
            }
            .buttonStyle(MaycastIconButtonStyle(active: isActive, size: 24))
            .disabled(!canPlay)
            .opacity(canPlay ? 1 : 0.4)
            .help("Play from here")

            // Start time — editable as mm:ss(.s)
            MaycastTextFieldBox(focused: timecodeFocused) {
                TextField("0:00", text: timecodeBinding)
                    .font(MaycastFont.mono(12, weight: .semibold))
                    .focused($timecodeFocused)
            }
            .frame(width: 92)

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
            }
            .buttonStyle(MaycastIconButtonStyle(size: 24, destructive: true))
            .help("Remove chapter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: MaycastRadius.inner, style: .continuous)
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
    var apiKeyLabel: String? = "••••2f1a"
    @State var preview: ChapterPreviewState = ChapterPreviewState(isReady: true, totalDuration: 2400)
    var size: CGSize = CGSize(width: 1100, height: 760)

    var body: some View {
        ChapterEditorView(
            episodeID: EpisodeBundle.sampleWithTracks.episode.id,
            chapters: $chapters,
            generation: generation,
            transcribe: transcribe,
            hasTranscript: hasTranscript,
            apiKeyConfigured: apiKeyConfigured,
            apiKeyLabel: apiKeyConfigured ? apiKeyLabel : nil,
            preview: preview,
            onDelete: { id in chapters.removeAll { $0.id == id } },
            onBack: {},
            onDone: {},
            onTogglePlay: { preview.isPlaying.toggle() },
            onSeek: { preview.currentTime = $0 },
            onPlayChapter: { ch in
                preview.currentTime = ch.startSec
                preview.isPlaying = true
            }
        )
        .frame(width: size.width, height: size.height)
    }
}

#Preview("Idle — with chapters") {
    ChapterEditorPreviewHost(chapters: chapterSamples)
}

#Preview("Playing — chapter 2 active") {
    ChapterEditorPreviewHost(
        chapters: chapterSamples,
        preview: ChapterPreviewState(isReady: true, isPlaying: true, currentTime: 120, totalDuration: 2400)
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

#Preview("Needs API key") {
    ChapterEditorPreviewHost(chapters: [], apiKeyConfigured: false)
}

#Preview("No transcript — can transcribe") {
    ChapterEditorPreviewHost(chapters: [], hasTranscript: false)
}

#Preview("Transcribing") {
    ChapterEditorPreviewHost(
        chapters: [],
        transcribe: .running(status: "Transcribing host…"),
        hasTranscript: false
    )
}

#Preview("Audio load failed") {
    ChapterEditorPreviewHost(
        chapters: chapterSamples,
        preview: ChapterPreviewState(isReady: false, loadError: "Failed to load tracks: file not found")
    )
}

#Preview("Empty — no chapters") {
    ChapterEditorPreviewHost(chapters: [])
}

#Preview("Compact window") {
    ChapterEditorPreviewHost(chapters: chapterSamples, size: CGSize(width: 720, height: 520))
}
#endif
