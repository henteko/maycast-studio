import SwiftUI
import AVFoundation
import MaycastCore

// MARK: - PolishSheet

struct PolishSheet: View {
    let bundle: EpisodeBundle
    let onDone: () -> Void
    /// Return to the episode view. Rendered inline in the main window now
    /// (not a sheet), so closing is an explicit callback rather than dismiss.
    let onClose: () -> Void

    /// Last service the user picked, remembered across episodes.
    @AppStorage("polish.provider") private var storedProvider: String = PolishProvider.auphonic.rawValue

    @State private var tracks: [PolishTrackSummary] = []
    @State private var settings: PolishSettings = .defaults
    @State private var status: PolishStatus = .idle
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var apiKeyStatus: PolishView.ApiKeyStatus = .missing
    @State private var showingSettings = false
    @State private var activeTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading {
                placeholderShell {
                    MaycastStatusBanner(tone: .progress, title: "Reading tracks…", spinning: true)
                        .frame(maxWidth: 420)
                }
            } else if let error = loadError {
                placeholderShell {
                    MaycastStatusBanner(
                        tone: .danger, icon: "exclamationmark.triangle.fill",
                        title: "Failed to read tracks", detail: error
                    )
                    .frame(maxWidth: 520)
                }
            } else {
                PolishView(
                    episodeID: bundle.episode.id,
                    tracks: tracks,
                    apiKeyStatus: apiKeyStatus,
                    settings: $settings,
                    status: $status,
                    onApply: apply,
                    onCancel: { activeTask?.cancel() },
                    onConfigureAPIKey: { showingSettings = true },
                    onBack: { onClose() }
                )
            }
        }
        .task {
            settings.provider = PolishProvider(rawValue: storedProvider) ?? .auphonic
            refreshAPIKeyStatus()
            await loadInitialState()
        }
        .onChange(of: settings.provider) { _, provider in
            storedProvider = provider.rawValue
            // A finished / failed run belongs to the other service; start clean.
            if !status.isActive { status = .idle }
            refreshAPIKeyStatus()
        }
        .sheet(isPresented: $showingSettings) {
            let service = settings.provider.apiKeyService
            ApiKeySettingsSheet(service: service, hasExistingKey: ApiKeyKeychain(service).loadKey() != nil) { _ in
                refreshAPIKeyStatus()
            }
        }
        .onDisappear { activeTask?.cancel() }
    }

    /// Shell with the back button but no footer, for the loading / failed
    /// states — the user can always leave the pane.
    private func placeholderShell<Body: View>(@ViewBuilder body: () -> Body) -> some View {
        MaycastOperationShell(
            episodeID: bundle.episode.id,
            icon: "wand.and.stars",
            tone: .mint,
            title: "Polish",
            subtitle: "Clean up every track via \(settings.provider.displayName)",
            onBack: onClose
        ) {
            VStack { Spacer(); body(); Spacer() }
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    private func loadKey() -> String? {
        ApiKeyKeychain(settings.provider.apiKeyService).loadKey()
    }

    private func refreshAPIKeyStatus() {
        if let key = loadKey() {
            apiKeyStatus = .configured(label: ApiKeyKeychain.maskedLabel(for: key))
            if case .needsApiKey = status { status = .idle }
        } else {
            apiKeyStatus = .missing
            if case .idle = status { status = .needsApiKey }
        }
    }

    private func loadInitialState() async {
        let tracks = bundle.episode.tracks
        let bundleURL = bundle.url
        do {
            // Only duration is needed up front — read it from the audio
            // header instead of loading samples, so the sheet opens
            // essentially instantly even on long episodes. The actual
            // cleanup is offloaded to the service, so there's nothing
            // local to compute here.
            let summaries: [PolishTrackSummary] = try await Task.detached(priority: .userInitiated) {
                var result: [PolishTrackSummary] = []
                for track in tracks {
                    let url = bundleURL.appendingPathComponent(track.current)
                    let duration = (try? MixSheet.fastDuration(at: url)) ?? 0
                    result.append(PolishTrackSummary(
                        id: track.id,
                        currentPath: track.current,
                        duration: duration,
                        hasVideo: track.hasVideo
                    ))
                }
                return result
            }.value
            self.tracks = summaries
            self.isLoading = false
        } catch {
            self.loadError = String(describing: error)
            self.isLoading = false
        }
    }

    // MARK: - Apply

    private func apply() {
        guard let apiKey = loadKey() else {
            status = .needsApiKey
            showingSettings = true
            return
        }
        guard !tracks.isEmpty else { return }

        activeTask?.cancel()
        let bundleURL = bundle.url
        let speakers = tracks.map { PolishSpeaker(id: $0.id, fileURL: bundleURL.appendingPathComponent($0.currentPath)) }
        let engine = makeEngine(apiKey: apiKey, settings: settings)
        status = .uploading(progress: Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, 0.0) }))

        activeTask = Task { @MainActor in
            do {
                let outputs = try await engine.run(bundleURL: bundleURL, speakers: speakers) { progress in
                    Task { @MainActor in
                        // Late ticks must not overwrite a finished / cancelled run.
                        if status.isActive { status = PolishStatus(progress) }
                    }
                }
                status = .completed(results: outputs.map {
                    PolishTrackResult(id: $0.trackID, generationPath: $0.generationPath)
                })
                onDone()
            } catch is CancellationError {
                status = .failed(message: "Cancelled.")
            } catch {
                status = .failed(message: String(describing: error))
            }
        }
    }
}

/// The engine for the selected service, configured from that service's options.
private func makeEngine(apiKey: String, settings: PolishSettings) -> any PolishEngine {
    switch settings.provider {
    case .auphonic: return AuphonicPolishEngine(apiKey: apiKey, options: settings.auphonic)
    case .cleanvoice: return CleanvoicePolishEngine(apiKey: apiKey, options: settings.cleanvoice)
    }
}

// MARK: - MixSheet

struct MixSheet: View {
    let bundle: EpisodeBundle
    let onDone: () -> Void
    /// Return to the episode view. Rendered inline in the main window.
    let onClose: () -> Void

    @State private var summaries: [MixTrackSummary] = []
    @State private var outputPath: String = ""
    @State private var status: MixState = .idle
    @State private var overlay: MixOverlaySettings = .defaults
    @State private var introDuration: Double = 0
    @State private var outroDuration: Double = 0
    @State private var preview: MixPreviewState = .idle
    @State private var previewTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var previewPlayer = MixPreviewPlayer()
    @State private var mixProgress = ProgressRelay()
    @State private var mixTask: Task<Void, Never>?

    private let operations = OperationsService()

    /// Shell with the back button but no footer, for the loading / failed
    /// states — the user can always leave the pane.
    private func placeholderShell<Body: View>(@ViewBuilder body: () -> Body) -> some View {
        MaycastOperationShell(
            episodeID: bundle.episode.id,
            icon: "square.stack.3d.down.forward",
            tone: .sun,
            title: "Mix",
            subtitle: "Combine every track with the Show's intro / outro",
            onBack: onClose
        ) {
            VStack { Spacer(); body(); Spacer() }
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                placeholderShell {
                    MaycastStatusBanner(tone: .progress, title: "Reading tracks…", spinning: true)
                        .frame(maxWidth: 420)
                }
            } else if let error = loadError {
                placeholderShell {
                    MaycastStatusBanner(
                        tone: .danger, icon: "exclamationmark.triangle.fill",
                        title: "Failed to read tracks", detail: error
                    )
                    .frame(maxWidth: 520)
                }
            } else {
                MixView(
                    episodeID: bundle.episode.id,
                    tracks: summaries,
                    outputPath: $outputPath,
                    state: $status,
                    overlay: $overlay,
                    introDurationSec: introDuration,
                    outroDurationSec: outroDuration,
                    preview: preview,
                    onMix: mix,
                    onCancel: cancelMix,
                    onReveal: reveal,
                    onPreview: previewOverlap,
                    onStopPreview: stopPreview,
                    onBack: { onClose() }
                )
            }
        }
        .task { await loadInitialState() }
        .onDisappear { stopPreview(); mixTask?.cancel() }
        .onChange(of: previewPlayer.isPlaying) { _, playing in
            if !playing, case .playing = preview {
                preview = .idle
            }
        }
        .onChange(of: mixProgress.fraction) { _, f in
            if case .mixing = status { status = .mixing(progress: f) }
        }
    }

    private func loadInitialState() async {
        let tracks = bundle.episode.tracks
        let bundleURL = bundle.url
        let cfg = bundle.episode.mix
        let introURL = cfg.intro.map { bundleURL.appendingPathComponent($0) }
        let outroURL = cfg.outro.map { bundleURL.appendingPathComponent($0) }
        do {
            // Only durations are needed — read via AVAudioFile header instead
            // of loading samples, and do it off-main so the sheet doesn't
            // freeze on a long episode.
            let built: [MixTrackSummary]
            let introDur: Double
            let outroDur: Double
            (built, introDur, outroDur) = try await Task.detached(priority: .userInitiated) { () -> ([MixTrackSummary], Double, Double) in
                var rows: [MixTrackSummary] = []
                for track in tracks {
                    let url = bundleURL.appendingPathComponent(track.current)
                    let d = try Self.fastDuration(at: url)
                    rows.append(MixTrackSummary(id: track.id, currentPath: track.current, duration: d))
                }
                let intro = introURL.flatMap { try? Self.fastDuration(at: $0) } ?? 0
                let outro = outroURL.flatMap { try? Self.fastDuration(at: $0) } ?? 0
                return (rows, intro, outro)
            }.value
            self.summaries = built
            self.outputPath = "exports/\(bundle.episode.id).mp3"
            self.overlay = MixOverlaySettings(
                introPath: cfg.intro,
                outroPath: cfg.outro,
                introOffsetSec: cfg.introOffsetSec,
                outroOffsetSec: cfg.outroOffsetSec,
                duckingGainDB: cfg.duckingGainDB,
                duckingFadeSec: cfg.duckingFadeSec
            )
            self.introDuration = introDur
            self.outroDuration = outroDur
            // If a previously-saved overlap is now longer than the actual
            // file (e.g. the user swapped in a shorter intro), clamp it down
            // so the slider stays in bounds.
            if introDuration > 0 { overlay.introOffsetSec = min(overlay.introOffsetSec, introDuration) }
            if outroDuration > 0 { overlay.outroOffsetSec = min(overlay.outroOffsetSec, outroDuration) }
            self.isLoading = false
        } catch {
            self.loadError = String(describing: error)
            self.isLoading = false
        }
    }

    private func mix() {
        guard !outputPath.isEmpty else { return }
        mixTask?.cancel()
        mixProgress.reset()
        status = .mixing(progress: 0)
        let bundleURL = bundle.url
        let outPath = outputPath
        let snapshot = overlay
        let relay = mixProgress
        mixTask = Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try OperationsService().runMix(
                        bundleURL: bundleURL,
                        outputPath: outPath,
                        overlay: snapshot,
                        onProgress: { f in Task { @MainActor in relay.update(f) } }
                    )
                }.value
                // A cancelled run may still finish writing; don't report it
                // as the current result once the user has backed out.
                try Task.checkCancellation()
                status = .completed(path: result.relativePath, duration: result.duration, byteSize: result.byteSize)
                onDone()
            } catch is CancellationError {
                status = .failed(message: "Cancelled.")
            } catch {
                status = .failed(message: String(describing: error))
            }
        }
    }

    private func cancelMix() {
        mixTask?.cancel()
        mixTask = nil
        if case .mixing = status { status = .failed(message: "Cancelled.") }
    }

    // MARK: - Overlap preview

    private func previewOverlap(_ kind: MixOverlapKind) {
        previewTask?.cancel()
        stopPreview()
        let snapshot = overlay
        let bundleURL = bundle.url
        preview = .rendering(kind: kind)
        previewTask = Task { @MainActor in
            do {
                let buffer = try await renderMixOverlapPreview(
                    kind: kind,
                    bundleURL: bundleURL,
                    overlay: snapshot
                )
                try Task.checkCancellation()
                try previewPlayer.play(buffer)
                preview = .playing(kind: kind)
            } catch is CancellationError {
                preview = .idle
            } catch {
                preview = .failed(message: String(describing: error))
            }
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewPlayer.stop()
        if case .rendering = preview {
            // leave any error/playing transition to set the state itself
            preview = .idle
        }
        if case .playing = preview {
            preview = .idle
        }
    }

    /// Cheap duration probe — uses `AVAudioFile` so we don't load samples
    /// just to know how long the intro/outro is.
    private func audioDuration(at url: URL?) -> Double {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return (try? Self.fastDuration(at: url)) ?? 0
    }

    /// Same as `audioDuration` but throws + is `nonisolated` so the
    /// `Task.detached` body can use it.
    fileprivate static func fastDuration(at url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return Double(file.length) / sr
    }

    private func reveal() {
        if case .completed(let path, _, _) = status {
            let url = bundle.url.appendingPathComponent(path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - ChapterSheet

struct ChapterSheet: View {
    let bundle: EpisodeBundle
    let onDone: () -> Void
    /// Return to the episode view. Rendered inline in the main window.
    let onClose: () -> Void

    @State private var chapters: [ChapterDraft] = []
    @State private var generation: ChapterGenerationState = .idle
    @State private var transcribe: ChapterTranscribeState = .idle
    @State private var hasTranscript = false
    /// Masked label of the Gemini key in the Keychain, e.g. "configured
    /// (••••2f1a)". `nil` ⇒ no key set (gates generation). Refreshed whenever
    /// the settings sheet changes the key.
    @State private var apiKeyLabel: String? = GeminiKeychain.loadKey().map(GeminiKeychain.maskedLabel(for:))
    @State private var showingKeySettings = false
    /// Audio preview: plays the voice-timeline mix so the user can hear where
    /// each chapter actually starts. Chapter `startSec` values are on the same
    /// timeline the engine plays, so a seek lands exactly on the boundary.
    @State private var playback = PlaybackEngine()
    @State private var audioReady = false
    /// In-flight Gemini generation, so the pane's Cancel can abort it.
    @State private var generationTask: Task<Void, Never>?

    private let operations = OperationsService()

    /// Build the value-type preview snapshot the editor renders from the
    /// `@Observable` engine. Reading the engine here ties body re-renders to
    /// playhead / isPlaying changes.
    private var previewState: ChapterPreviewState {
        ChapterPreviewState(
            isReady: audioReady,
            isPlaying: playback.isPlaying,
            currentTime: playback.playheadTime,
            totalDuration: playback.totalDuration,
            loadError: playback.lastError
        )
    }

    var body: some View {
        ChapterEditorView(
            episodeID: bundle.episode.id,
            chapters: $chapters,
            generation: generation,
            transcribe: transcribe,
            hasTranscript: hasTranscript,
            apiKeyConfigured: apiKeyLabel != nil,
            apiKeyLabel: apiKeyLabel,
            preview: previewState,
            onGenerate: { generate() },
            onCancelGeneration: { cancelGeneration() },
            onTranscribe: { runTranscription() },
            onAddChapter: { addChapter() },
            onDelete: { id in chapters.removeAll { $0.id == id } },
            onBack: { onClose() },
            onDone: { save() },
            onConfigureKey: { showingKeySettings = true },
            onTogglePlay: { togglePlay() },
            onSeek: { playback.seek(to: $0) },
            onPlayChapter: { playChapter($0) }
        )
        .task { await load() }
        .onDisappear {
            playback.stop()
            generationTask?.cancel()
        }
        .sheet(isPresented: $showingKeySettings) {
            GeminiSettingsSheet(hasExistingKey: apiKeyLabel != nil) { newKey in
                apiKeyLabel = newKey.map(GeminiKeychain.maskedLabel(for:))
            }
        }
    }

    private func load() async {
        let url = bundle.url
        chapters = operations.loadChapters(bundleURL: url).map(ChapterDraft.init)
        hasTranscript = operations.hasAnyTranscript(bundleURL: url)
        await loadAudio()
    }

    /// Load each track's current arrangement into the engine. Headers only —
    /// no samples or waveforms — so the sheet stays responsive.
    private func loadAudio() async {
        let url = bundle.url
        var loadList: [(trackID: String, arrangement: Arrangement, sourceURL: URL)] = []
        do {
            for track in bundle.episode.tracks {
                let trackURL = url.appendingPathComponent(track.current)
                let file = try AVAudioFile(forReading: trackURL)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                let arr = (try bundle.currentArrangement(forTrackID: track.id))
                    ?? Arrangement.single(sourceDuration: duration)
                loadList.append((trackID: track.id, arrangement: arr, sourceURL: trackURL))
            }
        } catch {
            playback.lastError = "Failed to load audio: \(error)"
            return
        }
        guard !loadList.isEmpty else { return }
        playback.load(tracks: loadList)
        audioReady = playback.lastError == nil
    }

    private func togglePlay() {
        if playback.isPlaying { playback.pause() } else { playback.play() }
    }

    /// Jump the playhead to a chapter's start and play from there.
    private func playChapter(_ chapter: ChapterDraft) {
        playback.seek(to: chapter.startSec)
        if !playback.isPlaying { playback.play() }
    }

    private func addChapter() {
        // Default a new chapter just after the latest existing one.
        let nextStart = chapters.map(\.startSec).max() ?? 0
        chapters.append(ChapterDraft(startSec: nextStart, title: "New chapter", source: .manual))
    }

    /// Transcribe every track inline, then chapters can be generated. Mirrors
    /// the editor's "Transcribe all" flow (streaming, per-track status).
    private func runTranscription() {
        let url = bundle.url
        let trackIDs = bundle.episode.tracks.map(\.id)
        guard !trackIDs.isEmpty else {
            transcribe = .failed(message: "Episode has no tracks to transcribe.")
            return
        }
        transcribe = .running(status: "Preparing…")
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for trackID in trackIDs {
                    group.addTask { @MainActor in
                        await operations.transcribeStreaming(
                            bundleURL: url,
                            trackID: trackID,
                            locale: Locale(identifier: "ja-JP")
                        ) { state in
                            switch state {
                            case .generating(_, let status):
                                transcribe = .running(status: status ?? "Transcribing \(trackID)…")
                            case .failed(let message):
                                transcribe = .failed(message: message)
                            case .empty, .populated:
                                break
                            }
                        }
                    }
                }
            }
            hasTranscript = operations.hasAnyTranscript(bundleURL: url)
            if case .failed = transcribe {} else { transcribe = .idle }
        }
    }

    private func generate() {
        generationTask?.cancel()
        generation = .generating
        let url = bundle.url
        let apiKey = GeminiKeychain.loadKey()
        generationTask = Task { @MainActor in
            do {
                let result = try await operations.generateChapters(bundleURL: url, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                chapters = result.map(ChapterDraft.init)
                generation = .idle
            } catch is CancellationError {
                generation = .idle
            } catch {
                guard !Task.isCancelled else { return }
                generation = .failed(message: String(describing: error))
            }
        }
    }

    private func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generation = .idle
    }

    private func save() {
        let url = bundle.url
        let toSave = chapters.map(\.asChapter)
        do {
            try operations.saveChapters(bundleURL: url, chapters: toSave)
            onDone()
            onClose()
        } catch {
            generation = .failed(message: String(describing: error))
        }
    }
}

// MARK: - EditorSheet

/// Live progress of a slice apply, driven from the background encode. Reading
/// `fraction` / `label` in a view body observes updates. MainActor-isolated, so
/// it's `Sendable` and safe to capture in the background progress callback (which
/// hops here before mutating).
@MainActor
@Observable
final class SliceApplyProgress {
    /// 0...1 across all changed tracks, or `nil` while indeterminate (e.g.
    /// audio-only edits that finish before any video-encode progress arrives).
    var fraction: Double?
    var label: String = "Applying…"

    func reset() {
        fraction = nil
        label = "Applying…"
    }

    func update(trackID: String, trackIndex: Int, trackCount: Int, fraction frac: Double) {
        fraction = (Double(trackIndex) + frac) / Double(max(1, trackCount))
        label = trackCount > 1
            ? "Applying \(trackID)… (\(trackIndex + 1)/\(trackCount))"
            : "Applying \(trackID)…"
    }
}

struct EditorSheet: View {
    let bundle: EpisodeBundle
    let onDone: () -> Void
    /// Return to the episode view. Rendered inline in the main window.
    let onClose: () -> Void

    @State private var state: EditorState?
    @State private var playback = PlaybackEngine()
    @State private var waveformCache = WaveformCache()
    @State private var trackOrder: [String] = []
    @State private var trackSources: [String: Double] = [:]
    @State private var trackPaths: [String: String] = [:]
    @State private var transcripts: [TranscriptTrackInfo] = []
    @State private var editCues: [EditCue] = []
    @State private var isDetectingEditCues = false
    @State private var loadError: String?
    @State private var applyError: String?
    /// Which step produced `applyError` ("Apply failed" vs edit-cue detection).
    @State private var applyErrorTitle: String = "Apply failed"
    @State private var applying = false
    @State private var applyProgress = SliceApplyProgress()

    private let operations = OperationsService()

    var body: some View {
        Group {
            if let state {
                EditorView(
                    episodeID: bundle.episode.id,
                    state: state,
                    playback: playback,
                    waveformCache: waveformCache,
                    trackOrder: trackOrder,
                    trackSources: trackSources,
                    trackPaths: trackPaths,
                    transcripts: transcripts,
                    editCues: editCues,
                    isDetectingEditCues: isDetectingEditCues,
                    applyStatus: applyStatus,
                    onApply: { apply(state: state) },
                    onTranscribeAll: { transcribeAll() },
                    onDetectEditCues: { detectEditCues() },
                    onBack: { onClose() }
                )
            } else if let error = loadError {
                placeholderShell {
                    MaycastStatusBanner(
                        tone: .danger, icon: "exclamationmark.triangle.fill",
                        title: "Failed to open editor", detail: error
                    )
                    .frame(maxWidth: 520)
                }
            } else {
                placeholderShell {
                    MaycastStatusBanner(tone: .progress, title: "Opening editor…", spinning: true)
                        .frame(maxWidth: 420)
                }
            }
        }
        .task { await loadInitialState() }
        .onDisappear { playback.stop() }
    }

    /// Footer state for the editor, derived from the host's apply bookkeeping.
    private var applyStatus: SliceApplyStatus {
        if applying {
            return .applying(label: applyProgress.label, fraction: applyProgress.fraction)
        }
        if let applyError {
            return .failed(title: applyErrorTitle, message: applyError)
        }
        return .idle
    }

    /// Shell with the back button but no footer, for the loading / failed
    /// states — the user can always leave the pane.
    private func placeholderShell<Body: View>(@ViewBuilder body: () -> Body) -> some View {
        MaycastOperationShell(
            episodeID: bundle.episode.id,
            icon: "scissors",
            tone: .sky,
            title: "Slice",
            subtitle: "Split, delete and move clips across tracks",
            onBack: onClose
        ) {
            VStack { Spacer(); body(); Spacer() }
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }

    private func loadInitialState() async {
        do {
            var arrs: [String: Arrangement] = [:]
            var sources: [String: Double] = [:]
            var order: [String] = []
            var paths: [String: String] = [:]
            var urls: [URL] = []
            var loadList: [(trackID: String, arrangement: Arrangement, sourceURL: URL)] = []
            // Fast pass: just read audio file headers (for duration) + arrangement JSON.
            // No samples loaded; this keeps the editor open instantly even on long files.
            for track in bundle.episode.tracks {
                let url = bundle.url.appendingPathComponent(track.current)
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                sources[track.id] = duration
                let arr = (try bundle.currentArrangement(forTrackID: track.id))
                    ?? Arrangement.single(sourceDuration: duration)
                arrs[track.id] = arr
                order.append(track.id)
                paths[track.id] = url.path
                urls.append(url)
                loadList.append((trackID: track.id, arrangement: arr, sourceURL: url))
            }
            playback.load(tracks: loadList)
            self.state = EditorState(initialArrangements: arrs)
            self.trackOrder = order
            self.trackSources = sources
            self.trackPaths = paths

            // Load any transcripts that already exist on disk. Empty files
            // become `.empty` so the Transcribe-all button surfaces.
            self.transcripts = order.map { trackID in
                let segments = operations.loadCurrentTranscript(bundleURL: bundle.url, trackID: trackID)
                let trackState: TrackTranscriptState = segments.isEmpty
                    ? .empty
                    : .populated(segments: segments)
                return TranscriptTrackInfo(id: trackID, state: trackState)
            }

            // Surface any edit cues already detected on a previous visit.
            self.editCues = operations.loadEditCues(bundleURL: bundle.url)

            // Slow pass: compute waveforms off the main thread, one task per track.
            // The cache is @Observable so the editor re-renders as peaks arrive.
            startWaveformGeneration(urls: urls, cache: waveformCache)
        } catch {
            self.loadError = String(describing: error)
        }
    }

    private func transcribeAll() {
        let order = trackOrder
        // Mark every track as pending so the panel shows progress immediately.
        transcripts = order.map {
            TranscriptTrackInfo(id: $0, state: .generating(partialSegments: [], status: "Pending…"))
        }
        let bundleURL = bundle.url
        Task { @MainActor in
            // Run all tracks in parallel — each transcribeStreaming spins up
            // its own SpeechAnalyzer / SpeechTranscriber instance, so they
            // don't interfere. UI updates remain serialized on MainActor.
            await withTaskGroup(of: Void.self) { group in
                for trackID in order {
                    group.addTask { @MainActor in
                        await operations.transcribeStreaming(
                            bundleURL: bundleURL,
                            trackID: trackID,
                            locale: Locale(identifier: "ja-JP")
                        ) { newState in
                            if let idx = transcripts.firstIndex(where: { $0.id == trackID }) {
                                transcripts[idx] = TranscriptTrackInfo(id: trackID, state: newState)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Detect editing cues over the current transcript via Gemini and refresh
    /// the highlights. Gemini-only: surfaces an error if no key / on failure.
    private func detectEditCues() {
        guard !isDetectingEditCues else { return }
        isDetectingEditCues = true
        applyError = nil
        let bundleURL = bundle.url
        let apiKey = GeminiKeychain.loadKey()
        Task { @MainActor in
            defer { isDetectingEditCues = false }
            do {
                let cues = try await operations.generateEditCues(bundleURL: bundleURL, apiKey: apiKey)
                editCues = cues
            } catch {
                applyErrorTitle = "Edit-cue detection failed"
                applyError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }

    private nonisolated func startWaveformGeneration(urls: [URL], cache: WaveformCache) {
        // `.utility` yields to UI work — the editor stays responsive while peaks
        // are computed in the background. Peaks for each track appear as soon
        // as that track's task completes.
        Task.detached(priority: .utility) {
            await withTaskGroup(of: (URL, WaveformPeaks?).self) { group in
                for url in urls {
                    group.addTask {
                        let peaks = try? WaveformGenerator.generateStreaming(from: url)
                        return (url, peaks)
                    }
                }
                for await (url, peaks) in group {
                    if let peaks {
                        await MainActor.run {
                            cache.set(peaks, for: url.path)
                        }
                    }
                }
            }
        }
    }

    private func apply(state: EditorState) {
        applying = true
        applyError = nil
        applyErrorTitle = "Apply failed"
        applyProgress.reset()
        playback.stop()
        let bundleURL = bundle.url
        let drafts: [(String, Arrangement)] = state.changedTracks.compactMap { trackID in
            state.drafts[trackID].map { (trackID, $0) }
        }
        let batchID = UUID().uuidString
        let progress = applyProgress   // MainActor-isolated ⇒ Sendable
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let ops = OperationsService()
                    let total = drafts.count
                    for (index, (trackID, draft)) in drafts.enumerated() {
                        _ = try ops.runSliceApply(
                            bundleURL: bundleURL,
                            trackID: trackID,
                            arrangement: draft,
                            batchID: batchID,
                            onVideoProgress: { frac in
                                Task { @MainActor in
                                    progress.update(trackID: trackID, trackIndex: index, trackCount: total, fraction: frac)
                                }
                            }
                        )
                    }
                }.value
                applying = false
                onDone()
                onClose()
            } catch {
                applying = false
                applyError = String(describing: error)
            }
        }
    }
}
