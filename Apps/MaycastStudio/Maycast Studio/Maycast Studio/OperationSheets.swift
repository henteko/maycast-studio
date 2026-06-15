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
                ProgressView("Reading tracks…")
                    .frame(minWidth: 400, minHeight: 200)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Text("Failed to read tracks").font(.headline)
                    Text(error).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Button("Close") { onClose() }
                }
                .padding()
                .frame(minWidth: 400, minHeight: 200)
            } else {
                PolishView(
                    tracks: tracks,
                    apiKeyStatus: apiKeyStatus,
                    settings: $settings,
                    status: $status,
                    onApply: apply,
                    onCancel: { activeTask?.cancel() },
                    onConfigureAPIKey: { showingSettings = true },
                    onClose: { onClose() }
                )
            }
        }
        .task {
            refreshAPIKeyStatus()
            await loadInitialState()
        }
        .sheet(isPresented: $showingSettings) {
            AuphonicSettingsSheet(hasExistingKey: AuphonicKeychain.loadKey() != nil) { _ in
                refreshAPIKeyStatus()
            }
        }
        .onDisappear { activeTask?.cancel() }
    }

    private func refreshAPIKeyStatus() {
        if let key = AuphonicKeychain.loadKey() {
            apiKeyStatus = .configured(label: AuphonicKeychain.maskedLabel(for: key))
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
            // loudness work is offloaded to Auphonic, so there's nothing
            // local to compute here.
            let summaries: [PolishTrackSummary] = try await Task.detached(priority: .userInitiated) {
                var result: [PolishTrackSummary] = []
                for track in tracks {
                    let url = bundleURL.appendingPathComponent(track.current)
                    let duration = (try? MixSheet.fastDuration(at: url)) ?? 0
                    result.append(PolishTrackSummary(
                        id: track.id,
                        currentPath: track.current,
                        duration: duration
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

    // MARK: - Apply (Auphonic pipeline)

    private func apply() {
        guard let apiKey = AuphonicKeychain.loadKey() else {
            status = .needsApiKey
            showingSettings = true
            return
        }
        guard !tracks.isEmpty else { return }

        activeTask?.cancel()
        let bundleURL = bundle.url
        let speakers = tracks.map { (id: $0.id, fileURL: bundleURL.appendingPathComponent($0.currentPath)) }
        let snapshotSettings = settings
        let initialUpload = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, 0.0) })
        status = .uploading(progress: initialUpload)

        activeTask = Task { @MainActor in
            do {
                let results = try await runAuphonicPipeline(
                    apiKey: apiKey,
                    bundleURL: bundleURL,
                    speakers: speakers,
                    settings: snapshotSettings,
                    updateStatus: { status = $0 }
                )
                status = .completed(results: results)
                onDone()
            } catch is CancellationError {
                status = .failed(message: "Cancelled.")
            } catch let e as AuphonicError {
                status = .failed(message: e.description)
            } catch {
                status = .failed(message: String(describing: error))
            }
        }
    }
}

/// Run the full Auphonic Multitrack pipeline and write one cleaned generation
/// per speaker into the bundle. Pure function on top of `AuphonicClient` and
/// `EpisodeBundle`, so it can be re-used (or unit-tested with a mocked client)
/// without depending on SwiftUI state.
@MainActor
private func runAuphonicPipeline(
    apiKey: String,
    bundleURL: URL,
    speakers: [(id: String, fileURL: URL)],
    settings: PolishSettings,
    updateStatus: @MainActor @escaping (PolishStatus) -> Void
) async throws -> [PolishTrackResult] {
    let client = AuphonicClient(apiKey: apiKey)

    // 1) Create production
    let payload = makeAuphonicPayload(settings: settings, speakers: speakers, bundleURL: bundleURL)
    let production = try await client.createProduction(payload: payload)
    let uuid = production.uuid

    do {
        // 2) Upload tracks. We don't have per-byte upload progress; mark each
        //    track as 1.0 after its upload completes.
        var uploadProgress = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, 0.0) })
        updateStatus(.uploading(progress: uploadProgress))
        for sp in speakers {
            try Task.checkCancellation()
            try await client.uploadTrack(uuid: uuid, trackID: sp.id, fileURL: sp.fileURL)
            uploadProgress[sp.id] = 1.0
            updateStatus(.uploading(progress: uploadProgress))
        }

        // 3) Start
        _ = try await client.startProduction(uuid: uuid)

        // 4) Poll. Status strings change as Auphonic moves through phases.
        updateStatus(.processing(statusString: "starting"))
        let done = try await client.pollUntilDone(uuid: uuid) { tick in
            Task { @MainActor in
                updateStatus(.processing(statusString: tick.statusString ?? "running"))
            }
        }

        // 5) Find the per-track ZIP output.
        guard let tracksOutput = done.outputFiles?.first(where: { $0.format == "tracks" }),
              let downloadURLString = tracksOutput.downloadURL,
              let downloadURL = URL(string: downloadURLString)
        else {
            throw AuphonicError.unexpected("Auphonic returned no per-track ZIP output")
        }

        // 6) Download the tracks ZIP (with progress).
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("auphonic-\(uuid)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let zipURL = tmpDir.appendingPathComponent("tracks.zip")
        var dlProgress = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, 0.0) })
        updateStatus(.downloading(progress: dlProgress))
        try await client.download(from: downloadURL, to: zipURL) { p in
            Task { @MainActor in
                for sp in speakers { dlProgress[sp.id] = p }
                updateStatus(.downloading(progress: dlProgress))
            }
        }

        // 7) Unzip.
        let extracted = try ZipExtractor.extract(archive: zipURL, to: tmpDir.appendingPathComponent("unzipped"))

        // 8) Match extracted files to speaker IDs and write one polish
        //    generation per track. We use boundary-based name matching so
        //    Auphonic's typical naming (`<title>_<id>.wav`,
        //    `<uuid>_<id>.wav`, or plain `<id>.wav`) all work, and prefer
        //    longer speaker IDs to avoid `host` swallowing `host2`.
        let speakerIDs = speakers.map(\.id)
        let audioExtensions: Set<String> = ["wav", "flac", "mp3", "m4a", "aiff", "aif"]
        let audioFiles = extracted.extractedFiles.filter {
            audioExtensions.contains($0.pathExtension.lowercased())
        }
        var fileBySpeaker: [String: URL] = [:]
        for file in audioFiles {
            let stem = file.deletingPathExtension().lastPathComponent
            if let id = matchSpeakerID(in: stem, candidates: speakerIDs) {
                if fileBySpeaker[id] == nil {
                    fileBySpeaker[id] = file
                }
            }
        }

        var bundle = try EpisodeBundle.open(at: bundleURL)
        let paramsJSON = makeParamsJSON(settings: settings)
        // Shared batchID so a single undo reverts every speaker's polish at
        // once, matching the "one Apply press = one undo step" mental model.
        let polishBatchID = UUID().uuidString
        var results: [PolishTrackResult] = []
        for sp in speakers {
            guard let extractedFile = fileBySpeaker[sp.id] else {
                throw AuphonicError.unexpected("Could not find cleaned track for '\(sp.id)' in ZIP. Files: \(audioFiles.map { $0.lastPathComponent })")
            }
            let cleanedBuffer = try AudioIO.read(from: extractedFile)
            let track = try bundle.appendOperationGeneration(
                trackID: sp.id,
                operation: "polish",
                params: paramsJSON,
                batchID: polishBatchID
            ) { _ in cleanedBuffer }
            results.append(PolishTrackResult(
                id: sp.id,
                generationPath: track.current
            ))
        }

        // 9) Best-effort cleanup of the Auphonic production. Skipped when
        //    `keepProduction` is on so the user can inspect the run on
        //    Auphonic's dashboard. Failures are non-fatal either way — the
        //    audio is already saved locally.
        if !settings.keepProduction {
            try? await client.deleteProduction(uuid: uuid)
        }
        try? FileManager.default.removeItem(at: tmpDir)

        return results
    } catch {
        // If we failed mid-pipeline, leave the Auphonic production around so
        // the user can inspect it. Only the local temp dir is torn down.
        throw error
    }
}

private func makeAuphonicPayload(
    settings: PolishSettings,
    speakers: [(id: String, fileURL: URL)],
    bundleURL: URL
) -> Auphonic.ProductionPayload {
    let perTrackBreath = settings.debreathAmount != .off
    let multi: [Auphonic.MultiInputFile] = speakers.map { sp in
        var entry = Auphonic.MultiInputFile(type: "multitrack", id: sp.id)
        // Force every speaker track to be treated as foreground so the
        // Adaptive Leveler doesn't auto-detect a quieter speaker as
        // background and duck them into near-silence.
        var algos = Auphonic.Algorithms(backforeground: "foreground")
        if perTrackBreath {
            algos.debreathAmount = Double(settings.debreathAmount.rawValue)
        }
        entry.algorithms = algos
        return entry
    }

    var algorithms = Auphonic.Algorithms(
        fadetime: 250,
        loudnessTarget: settings.loudnessTarget,
        hipfilter: settings.hipfilterEnabled
    )
    if settings.levelerEnabled { algorithms.leveler = true }
    if settings.denoiseEnabled {
        algorithms.denoise = true
        algorithms.denoiseMethod = settings.denoiseMethod.rawValue
    }
    if settings.fillerCutterEnabled || settings.silenceCutterEnabled || settings.coughCutterEnabled {
        algorithms.cutMode = "apply_cuts"
        if settings.fillerCutterEnabled { algorithms.fillerCutter = true }
        if settings.silenceCutterEnabled { algorithms.silenceCutter = true }
        if settings.coughCutterEnabled { algorithms.coughCutter = true }
    }

    let title = "maycast-\(bundleURL.deletingPathExtension().lastPathComponent)-\(ISO8601DateFormatter().string(from: Date()))"
    return Auphonic.ProductionPayload(
        isMultitrack: true,
        metadata: Auphonic.ProductionPayload.Metadata(title: title),
        multiInputFiles: multi,
        algorithms: algorithms,
        outputFiles: [
            // We always ask for a cheap mp3 master (Auphonic requires at least
            // one master output) — Maycast's own Mix flow does the final mix,
            // so we never actually download this file.
            Auphonic.OutputFile(format: "mp3"),
            Auphonic.OutputFile(format: "tracks", ending: "wav.zip"),
        ]
    )
}

/// Pick the speaker ID that appears as a delimited token in `haystack`.
/// Boundary characters = anything non-alphanumeric, plus the start / end of
/// the string. The longest match wins so `"audio_xxx_host2"` resolves to
/// `host2` instead of `host`.
private func matchSpeakerID(in haystack: String, candidates: [String]) -> String? {
    let lower = haystack.lowercased()
    let matches = candidates.filter { id in
        let needle = id.lowercased()
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        let pattern = "(^|[^a-z0-9])\(escaped)([^a-z0-9]|$)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(lower.startIndex..., in: lower)
        return re.firstMatch(in: lower, range: range) != nil
    }
    return matches.sorted { $0.count > $1.count }.first
}

private func makeParamsJSON(settings: PolishSettings) -> JSONValue {
    var dict: [String: JSONValue] = [
        "provider": .string("auphonic"),
        "loudness": .number(settings.loudnessTarget),
        "leveler": .bool(settings.levelerEnabled),
        "denoise": .bool(settings.denoiseEnabled),
        "denoise_method": .string(settings.denoiseMethod.rawValue),
        "filler_cutter": .bool(settings.fillerCutterEnabled),
        "silence_cutter": .bool(settings.silenceCutterEnabled),
        "cough_cutter": .bool(settings.coughCutterEnabled),
        "debreath_amount": .integer(settings.debreathAmount.rawValue),
        "hipfilter": .bool(settings.hipfilterEnabled),
    ]
    _ = dict.count  // silence unused-mutation warnings if any
    return .object(dict)
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

    private let operations = OperationsService()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Reading tracks…")
                    .frame(minWidth: 400, minHeight: 200)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Text("Failed to read tracks").font(.headline)
                    Text(error).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Button("Close") { onClose() }
                }
                .padding()
                .frame(minWidth: 400, minHeight: 200)
            } else {
                MixView(
                    tracks: summaries,
                    outputPath: $outputPath,
                    state: $status,
                    overlay: $overlay,
                    introDurationSec: introDuration,
                    outroDurationSec: outroDuration,
                    preview: preview,
                    onMix: mix,
                    onReveal: reveal,
                    onPreview: previewOverlap,
                    onStopPreview: stopPreview,
                    onClose: { onClose() }
                )
            }
        }
        .task { await loadInitialState() }
        .onDisappear { stopPreview() }
        .onChange(of: previewPlayer.isPlaying) { _, playing in
            if !playing, case .playing = preview {
                preview = .idle
            }
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
        status = .mixing(progress: 0.5)
        let bundleURL = bundle.url
        let outPath = outputPath
        let snapshot = overlay
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try OperationsService().runMix(
                        bundleURL: bundleURL,
                        outputPath: outPath,
                        overlay: snapshot
                    )
                }.value
                status = .completed(path: result.relativePath, duration: result.duration, byteSize: result.byteSize)
                onDone()
            } catch {
                status = .failed(message: String(describing: error))
            }
        }
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
            chapters: $chapters,
            generation: generation,
            transcribe: transcribe,
            hasTranscript: hasTranscript,
            apiKeyConfigured: apiKeyLabel != nil,
            apiKeyLabel: apiKeyLabel,
            preview: previewState,
            onGenerate: { generate() },
            onTranscribe: { runTranscription() },
            onAddChapter: { addChapter() },
            onDelete: { id in chapters.removeAll { $0.id == id } },
            onClose: { onClose() },
            onDone: { save() },
            onConfigureKey: { showingKeySettings = true },
            onTogglePlay: { togglePlay() },
            onSeek: { playback.seek(to: $0) },
            onPlayChapter: { playChapter($0) }
        )
        .task { await load() }
        .onDisappear { playback.stop() }
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
        generation = .generating
        let url = bundle.url
        let apiKey = GeminiKeychain.loadKey()
        Task {
            do {
                let result = try await operations.generateChapters(bundleURL: url, apiKey: apiKey)
                chapters = result.map(ChapterDraft.init)
                generation = .idle
            } catch {
                generation = .failed(message: String(describing: error))
            }
        }
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
    @State private var applying = false

    private let operations = OperationsService()

    var body: some View {
        Group {
            if let state {
                VStack(spacing: 0) {
                    EditorView(
                        state: state,
                        playback: playback,
                        waveformCache: waveformCache,
                        trackOrder: trackOrder,
                        trackSources: trackSources,
                        trackPaths: trackPaths,
                        transcripts: transcripts,
                        editCues: editCues,
                        isDetectingEditCues: isDetectingEditCues,
                        onApply: { apply(state: state) },
                        onTranscribeAll: { transcribeAll() },
                        onDetectEditCues: { detectEditCues() },
                        onClose: { onClose() }
                    )
                    if let applyError {
                        Divider()
                        Label(applyError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    if applying {
                        Divider()
                        HStack { ProgressView().controlSize(.small); Text("Applying…") }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Text("Failed to open editor").font(.headline)
                    Text(error).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Button("Close") { onClose() }
                }
                .padding()
                .frame(minWidth: 400, minHeight: 200)
            } else {
                ProgressView("Opening editor…")
                    .frame(minWidth: 600, minHeight: 300)
            }
        }
        .task { await loadInitialState() }
        .onDisappear { playback.stop() }
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
        playback.stop()
        let bundleURL = bundle.url
        let drafts: [(String, Arrangement)] = state.changedTracks.compactMap { trackID in
            state.drafts[trackID].map { (trackID, $0) }
        }
        let batchID = UUID().uuidString
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let ops = OperationsService()
                    for (trackID, draft) in drafts {
                        _ = try ops.runSliceApply(
                            bundleURL: bundleURL,
                            trackID: trackID,
                            arrangement: draft,
                            batchID: batchID
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
