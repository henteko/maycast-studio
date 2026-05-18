import SwiftUI
import AVFoundation
import MaycastCore

// MARK: - PolishSheet

struct PolishSheet: View {
    let bundle: EpisodeBundle
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [PolishTrackSummary] = []
    @State private var settings: PolishSettings = .defaults
    @State private var status: PolishStatus = .idle
    @State private var isLoading = true
    @State private var loadError: String?

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
                    Button("Close") { dismiss() }
                }
                .padding()
                .frame(minWidth: 400, minHeight: 200)
            } else {
                PolishView(tracks: tracks, settings: $settings, status: $status, onApply: apply)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        }
        .task { await loadInitialState() }
    }

    private func loadInitialState() async {
        var summaries: [PolishTrackSummary] = []
        do {
            for track in bundle.episode.tracks {
                let buffer = try AudioIO.read(from: bundle.url.appendingPathComponent(track.current))
                let lufs = Loudness.integratedLUFS(buffer)
                summaries.append(PolishTrackSummary(
                    id: track.id,
                    currentPath: track.current,
                    duration: buffer.duration,
                    measuredLUFS: lufs
                ))
            }
            self.tracks = summaries
            self.isLoading = false
        } catch {
            self.loadError = String(describing: error)
            self.isLoading = false
        }
    }

    private func apply() {
        guard settings.loudnessEnabled || settings.denoiseEnabled || settings.deEsserEnabled else { return }
        status = .processing
        do {
            let trackIDs = tracks.map(\.id)
            let target = settings.loudnessEnabled ? settings.loudnessTarget : nil
            let results = try operations.runPolishMulti(
                bundleURL: bundle.url,
                trackIDs: trackIDs,
                loudnessTarget: target
            )
            status = .completed(results: results.map {
                PolishTrackResult(id: $0.trackID, generationPath: $0.generationPath, measuredLUFS: $0.measuredLUFS)
            })
            onDone()
        } catch {
            status = .failed(message: String(describing: error))
        }
    }
}

// MARK: - MixSheet

struct MixSheet: View {
    let bundle: EpisodeBundle
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [MixTrackSummary] = []
    @State private var outputPath: String = ""
    @State private var status: MixState = .idle
    @State private var isLoading = true
    @State private var loadError: String?

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
                    Button("Close") { dismiss() }
                }
                .padding()
                .frame(minWidth: 400, minHeight: 200)
            } else {
                MixView(tracks: summaries, outputPath: $outputPath, state: $status, onMix: mix, onReveal: reveal)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        }
        .task { await loadInitialState() }
    }

    private func loadInitialState() async {
        do {
            var built: [MixTrackSummary] = []
            for track in bundle.episode.tracks {
                let buffer = try AudioIO.read(from: bundle.url.appendingPathComponent(track.current))
                built.append(MixTrackSummary(id: track.id, currentPath: track.current, duration: buffer.duration))
            }
            self.summaries = built
            self.outputPath = "exports/\(bundle.episode.id).wav"
            self.isLoading = false
        } catch {
            self.loadError = String(describing: error)
            self.isLoading = false
        }
    }

    private func mix() {
        guard !outputPath.isEmpty else { return }
        status = .mixing(progress: 0.5)
        do {
            let result = try operations.runMix(bundleURL: bundle.url, outputPath: outputPath)
            status = .completed(path: result.relativePath, duration: result.duration, byteSize: result.byteSize)
            onDone()
        } catch {
            status = .failed(message: String(describing: error))
        }
    }

    private func reveal() {
        if case .completed(let path, _, _) = status {
            let url = bundle.url.appendingPathComponent(path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - EditorSheet

struct EditorSheet: View {
    let bundle: EpisodeBundle
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: EditorState?
    @State private var playback = PlaybackEngine()
    @State private var waveformCache = WaveformCache()
    @State private var trackOrder: [String] = []
    @State private var trackSources: [String: Double] = [:]
    @State private var trackPaths: [String: String] = [:]
    @State private var transcripts: [TranscriptTrackInfo] = []
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
                        onApply: { apply(state: state) },
                        onTranscribeAll: { transcribeAll() }
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
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Text("Failed to open editor").font(.headline)
                    Text(error).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Button("Close") { dismiss() }
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
        do {
            for trackID in state.changedTracks {
                guard let draft = state.drafts[trackID] else { continue }
                _ = try operations.runSliceApply(bundleURL: bundle.url, trackID: trackID, arrangement: draft)
            }
            applying = false
            onDone()
            dismiss()
        } catch {
            applying = false
            applyError = String(describing: error)
        }
    }
}
