import Foundation
import AVFoundation
import CoreMedia
import os
import Speech

/// Wrapper around the macOS 26 `SpeechAnalyzer` / `SpeechTranscriber` APIs.
///
/// Streams transcription progress: a `.status(_)` update is emitted at each
/// pipeline phase (preparing, downloading model, analyzing) and a
/// `.segments(_)` update is emitted every time a new final phrase is recognised
/// (carrying the **cumulative** segment list).
///
/// ## Time mapping (pre-trim approach)
///
/// SpeechAnalyzer's VAD compresses silence out of its reported timestamps even
/// when we pass an explicit `bufferStartTime`. To get timestamps that line up
/// with the original file, we **pre-trim silence before feeding the analyzer**:
///
/// 1. Scan the file once and detect voiced regions.
/// 2. Feed only the voiced regions, concatenated, into the analyzer (with a
///    short silence padding between them so phrases stay separated).
/// 3. The analyzer reports timestamps in *concatenated* time, which we map back
///    to file time via `VoicedTimeMapper`.
public enum Transcription {
    public enum TranscribeError: Error, CustomStringConvertible, Sendable {
        case audioReadFailed(URL, underlying: Error)
        case bufferAllocationFailed
        case modelInstallFailed(String)
        case analyzerStartFailed(String)
        case streamFailed(String)
        case other(String)

        public var description: String {
            switch self {
            case .audioReadFailed(let url, let e): return "Failed to read audio at \(url.path): \(e)"
            case .bufferAllocationFailed: return "Failed to allocate audio buffer"
            case .modelInstallFailed(let s): return "Speech model install failed: \(s)"
            case .analyzerStartFailed(let s): return "SpeechAnalyzer failed to start: \(s)"
            case .streamFailed(let s): return "Speech analyzer stream failed: \(s)"
            case .other(let s): return s
            }
        }
    }

    public enum Update: Sendable {
        case status(String)
        case segments([TranscriptSegment])  // cumulative
    }

    /// A continuous voiced span in the source audio, measured in file time.
    struct VoicedRegion: Sendable, Equatable {
        let fileStart: Double
        let fileEnd: Double
        var duration: Double { fileEnd - fileStart }
    }

    /// Pure function: given a list of voiced regions and inter-region padding,
    /// translate a position in *concatenated* time (= the timeline the analyzer
    /// sees) back to file time.
    struct VoicedTimeMapper: Sendable {
        let regions: [VoicedRegion]
        let paddingBetween: Double

        /// Total length of the concatenated voiced stream (incl. padding).
        var concatDuration: Double {
            let voiced = regions.reduce(0.0) { $0 + $1.duration }
            let padding = paddingBetween * Double(max(0, regions.count - 1))
            return voiced + padding
        }

        func fileTime(forConcat concatT: Double) -> Double {
            guard !regions.isEmpty else { return concatT }
            if concatT <= 0 { return regions[0].fileStart }
            var cursor: Double = 0
            for (index, region) in regions.enumerated() {
                let regionEnd = cursor + region.duration
                if concatT <= regionEnd {
                    return region.fileStart + (concatT - cursor)
                }
                cursor = regionEnd
                // Padding gap before next region.
                if index < regions.count - 1, paddingBetween > 0 {
                    let paddingEnd = cursor + paddingBetween
                    if concatT < paddingEnd {
                        // Result lands inside an injected silence — snap to
                        // the boundary of the region we just left.
                        return region.fileEnd
                    }
                    cursor = paddingEnd
                }
            }
            return regions.last!.fileEnd
        }
    }

    /// Convenience: collects all updates from `transcribeStream` and returns
    /// only the final segment list.
    public static func transcribe(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) async throws -> [TranscriptSegment] {
        var last: [TranscriptSegment] = []
        for try await update in transcribeStream(audioURL: audioURL, locale: locale) {
            if case .segments(let s) = update { last = s }
        }
        return last
    }

    /// Streaming version. Yields status messages and growing segment lists as
    /// transcription progresses.
    ///
    /// Buffering is capped (`.bufferingNewest(4)`) so a slow consumer
    /// (MainActor + SwiftUI re-rendering) cannot accumulate a large backlog
    /// of stale updates — the UI always sees the latest state, not a
    /// 30-second-old preview.
    public static func transcribeStream(
        audioURL: URL,
        locale: Locale = Locale(identifier: "ja-JP")
    ) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let work = Task {
                do {
                    try await runStreaming(
                        audioURL: audioURL,
                        locale: locale,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - Core pipeline

    private static func runStreaming(
        audioURL: URL,
        locale: Locale,
        emit: @Sendable @escaping (Update) -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscribeError.other("Audio file not found at \(audioURL.path)")
        }
        log("audioURL=\(audioURL.lastPathComponent) locale=\(locale.identifier)")

        emit(.status("Preparing…"))

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        log("ensuring model availability")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                emit(.status("Downloading speech model for \(locale.identifier)…"))
                log("downloading model")
                try await request.downloadAndInstall()
                log("model installed")
            } else {
                log("model already installed")
            }
        } catch {
            throw TranscribeError.modelInstallFailed("\(error)")
        }

        emit(.status("Loading audio…"))

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let analyzerFormat: AVAudioFormat
        do {
            if let best = try await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
                analyzerFormat = best
            } else {
                throw TranscribeError.other("No compatible analyzer format for \(locale.identifier)")
            }
        } catch let err as TranscribeError {
            throw err
        } catch {
            throw TranscribeError.other("Failed to query analyzer audio format: \(error)")
        }
        log("analyzerFormat=\(analyzerFormat)")

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscribeError.audioReadFailed(audioURL, underlying: error)
        }
        let sourceFormat = audioFile.processingFormat
        let totalFrames = audioFile.length
        let totalDuration = Double(totalFrames) / sourceFormat.sampleRate
        log("sourceFormat=\(sourceFormat) totalFrames=\(totalFrames) duration=\(totalDuration)s")

        // Scan for voiced regions so we can pre-trim silence before feeding
        // the analyzer. If detection fails or returns nothing, fall back to
        // treating the whole file as one region (= original behaviour).
        emit(.status("Scanning audio…"))
        let detected: [VoicedRegion]
        do {
            detected = try await detectVoicedRegions(audioURL: audioURL)
        } catch {
            log("voiced-region detection failed: \(error) — feeding whole file as one region")
            detected = []
        }
        let voicedRegions: [VoicedRegion]
        if detected.isEmpty {
            voicedRegions = [VoicedRegion(fileStart: 0, fileEnd: totalDuration)]
            log("no voiced regions detected — using full file")
        } else {
            voicedRegions = detected
            let voicedTotal = detected.reduce(0.0) { $0 + $1.duration }
            log("voiced regions: count=\(detected.count) firstStart=\(detected[0].fileStart)s firstEnd=\(detected[0].fileEnd)s voicedTotal=\(voicedTotal)s of \(totalDuration)s")
        }
        let paddingBetween: Double = 0.3
        let mapper = VoicedTimeMapper(regions: voicedRegions, paddingBetween: paddingBetween)

        let needsConversion = sourceFormat != analyzerFormat
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            : nil
        if needsConversion, converter == nil {
            throw TranscribeError.other("Could not build converter from \(sourceFormat) to \(analyzerFormat)")
        }
        log("conversion=\(needsConversion)")

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // Run the analyzer concurrently with our audio feeding. `start` is
        // long-running — it consumes the input sequence until it finishes —
        // so we must NOT await it here, otherwise the feed loop never runs.
        emit(.status("Starting analyzer…"))
        log("analyzer.start (concurrent)")
        async let analyzerJob: Void = analyzer.start(inputSequence: inputStream)

        // Collect results in a child task. Final results are emitted
        // immediately; volatile (in-flight) results are throttled to avoid
        // drowning the MainActor in re-renders.
        let volatileThrottle: TimeInterval = 0.15
        let mapperCopy = mapper
        let resultsTask = Task<[TranscriptSegment], Error> {
            var finalised: [TranscriptSegment] = []
            var lastVolatileEmit: Date = .distantPast
            var loggedFinalCount = 0
            for try await result in transcriber.results {
                let rawSegs = extractWordSegments(from: result)
                let segs = rawSegs.map { seg in
                    TranscriptSegment(
                        start: mapperCopy.fileTime(forConcat: seg.start),
                        end: mapperCopy.fileTime(forConcat: seg.end),
                        text: seg.text
                    )
                }
                if result.isFinal {
                    if !segs.isEmpty {
                        finalised.append(contentsOf: segs)
                        if loggedFinalCount < 3 {
                            loggedFinalCount += 1
                            log("FINAL #\(loggedFinalCount) concatRange=\(result.range.start.seconds)–\(result.range.end.seconds)s mappedFirst=\(segs.first?.start ?? -1)s text=\(segs.map(\.text).joined(separator: " "))")
                        } else {
                            log("FINAL +\(segs.count) total=\(finalised.count) concatRange=\(result.range.start.seconds)–\(result.range.end.seconds)s text=\(segs.map(\.text).joined(separator: " "))")
                        }
                    } else {
                        log("FINAL (empty result) concatRange=\(result.range.start.seconds)–\(result.range.end.seconds)s")
                    }
                    emit(.segments(finalised))
                    lastVolatileEmit = Date()
                } else if !segs.isEmpty {
                    let now = Date()
                    if now.timeIntervalSince(lastVolatileEmit) >= volatileThrottle {
                        lastVolatileEmit = now
                        emit(.segments(finalised + segs))
                    }
                }
            }
            log("results stream closed, finalSegments=\(finalised.count)")
            emit(.segments(finalised))
            return finalised
        }

        emit(.status("Transcribing…"))

        // Feed loop: iterate over voiced regions, emitting silence padding
        // between them. `cumulativeAnalyzerFrames` tracks the position in the
        // concatenated analyzer-format timeline — which is exactly what we
        // feed via `bufferStartTime` and what the mapper inverts.
        let analyzerChunkFrames: AVAudioFrameCount = 8000   // ~0.5 s at 16 kHz
        let sourceReadFrames: AVAudioFrameCount = 4096
        let analyzerSampleRate = analyzerFormat.sampleRate

        let feeder = RegionFeeder(
            audioFile: audioFile,
            regions: voicedRegions,
            chunkFrames: sourceReadFrames,
            paddingBetween: paddingBetween
        )

        var chunksFed = 0
        var emptyOutputs = 0
        var cumulativeAnalyzerFrames: Int64 = 0
        var streamDone = false

        while !streamDone {
            try Task.checkCancellation()

            let outBuf: AVAudioPCMBuffer?
            if let conv = converter {
                guard let analyzerOut = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: analyzerChunkFrames) else {
                    inputContinuation.finish()
                    throw TranscribeError.bufferAllocationFailed
                }
                var convError: NSError?
                let status = conv.convert(to: analyzerOut, error: &convError) { _, statusOut in
                    if let sourceBuf = feeder.readNextChunk() {
                        statusOut.pointee = .haveData
                        return sourceBuf
                    }
                    statusOut.pointee = .endOfStream
                    return nil
                }
                if let convError {
                    inputContinuation.finish()
                    throw TranscribeError.streamFailed("Audio conversion failed: \(convError)")
                }
                if status == .error {
                    inputContinuation.finish()
                    throw TranscribeError.streamFailed("Converter reported .error status")
                }
                outBuf = analyzerOut.frameLength > 0 ? analyzerOut : nil
                if status == .endOfStream {
                    streamDone = true
                }
            } else {
                // No conversion needed — feeder produces analyzer-format buffers
                // already.
                if let buf = feeder.readNextChunk() {
                    outBuf = buf
                } else {
                    outBuf = nil
                    streamDone = true
                }
            }

            if let outBuf, outBuf.frameLength > 0 {
                let presentationTime = CMTime(
                    value: cumulativeAnalyzerFrames,
                    timescale: Int32(analyzerSampleRate)
                )
                inputContinuation.yield(AnalyzerInput(buffer: outBuf, bufferStartTime: presentationTime))
                chunksFed += 1
                cumulativeAnalyzerFrames += Int64(outBuf.frameLength)
                if chunksFed <= 3 || chunksFed % 100 == 0 {
                    let nowSeconds = Double(cumulativeAnalyzerFrames) / analyzerSampleRate
                    log("fed chunk #\(chunksFed) presentationTime=\(presentationTime.seconds)s cumulativeConcat=\(nowSeconds)s (len=\(outBuf.frameLength))")
                }
            } else {
                emptyOutputs += 1
                if emptyOutputs <= 5 {
                    log("converter returned empty buffer")
                }
            }
        }
        log("fed \(chunksFed) chunks (emptyOutputs=\(emptyOutputs)); closing input")

        inputContinuation.finish()
        emit(.status("Finalising…"))

        do {
            try await analyzerJob
            log("analyzerJob complete")
        } catch {
            log("analyzerJob threw: \(error)")
        }

        // `finalizeAndFinish` takes a time in concatenated (analyzer) time, not
        // file time, since that's what we fed in.
        let endTime = CMTime(
            seconds: max(0, mapper.concatDuration - 0.05),
            preferredTimescale: 1000
        )
        do {
            log("finalizeAndFinish through=\(endTime.seconds)s (concat duration=\(mapper.concatDuration)s)")
            try await analyzer.finalizeAndFinish(through: endTime)
            log("finalize complete")
        } catch {
            log("finalize threw: \(error)")
        }

        log("awaiting resultsTask…")
        _ = try? await resultsTask.value
        log("done")
    }

    // MARK: - Region feeder

    /// Reads voiced regions from `AVAudioFile` and yields chunks back-to-back,
    /// injecting `paddingBetween` seconds of silence between consecutive
    /// regions. The output is in the file's *source* format — the converter
    /// downstream resamples it to the analyzer's preferred format.
    /// `@unchecked Sendable` — the feeder is mutated only from inside the
    /// synchronous `AVAudioConverter` input-pull closure, which runs on the
    /// same task as the feed loop. Swift's strict concurrency can't see this
    /// invariant, but it holds at the call site.
    private final class RegionFeeder: @unchecked Sendable {
        let audioFile: AVAudioFile
        let sourceFormat: AVAudioFormat
        let regions: [VoicedRegion]
        let chunkFrames: AVAudioFrameCount
        let paddingFrames: Int64

        private var regionIndex = 0
        private var framesReadInRegion: Int64 = 0
        private var seekedForCurrentRegion = false
        private var inPadding = false
        private var paddingFramesEmitted: Int64 = 0

        init(
            audioFile: AVAudioFile,
            regions: [VoicedRegion],
            chunkFrames: AVAudioFrameCount,
            paddingBetween: Double
        ) {
            self.audioFile = audioFile
            self.sourceFormat = audioFile.processingFormat
            self.regions = regions
            self.chunkFrames = chunkFrames
            self.paddingFrames = Int64(paddingBetween * sourceFormat.sampleRate)
        }

        func readNextChunk() -> AVAudioPCMBuffer? {
            while regionIndex < regions.count {
                if inPadding {
                    let remaining = paddingFrames - paddingFramesEmitted
                    if remaining <= 0 {
                        inPadding = false
                        paddingFramesEmitted = 0
                        regionIndex += 1
                        framesReadInRegion = 0
                        seekedForCurrentRegion = false
                        continue
                    }
                    let toEmit = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
                    guard let buf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: toEmit) else {
                        return nil
                    }
                    buf.frameLength = toEmit
                    if let channels = buf.floatChannelData {
                        let chCount = Int(sourceFormat.channelCount)
                        for ch in 0..<chCount {
                            for i in 0..<Int(toEmit) { channels[ch][i] = 0 }
                        }
                    }
                    paddingFramesEmitted += Int64(toEmit)
                    return buf
                }

                let region = regions[regionIndex]
                let regionTotalFrames = Int64(region.duration * sourceFormat.sampleRate)
                let remaining = regionTotalFrames - framesReadInRegion
                if remaining <= 0 {
                    if regionIndex < regions.count - 1, paddingFrames > 0 {
                        inPadding = true
                        paddingFramesEmitted = 0
                        continue
                    }
                    regionIndex += 1
                    framesReadInRegion = 0
                    seekedForCurrentRegion = false
                    continue
                }

                if !seekedForCurrentRegion {
                    let startFrame = AVAudioFramePosition(region.fileStart * sourceFormat.sampleRate)
                    audioFile.framePosition = startFrame
                    seekedForCurrentRegion = true
                }

                let toRead = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
                guard let buf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: toRead) else {
                    return nil
                }
                do {
                    try audioFile.read(into: buf, frameCount: toRead)
                } catch {
                    return nil
                }
                if buf.frameLength == 0 {
                    if regionIndex < regions.count - 1, paddingFrames > 0 {
                        inPadding = true
                        paddingFramesEmitted = 0
                        continue
                    }
                    regionIndex += 1
                    framesReadInRegion = 0
                    seekedForCurrentRegion = false
                    continue
                }
                framesReadInRegion += Int64(buf.frameLength)
                return buf
            }
            return nil
        }
    }

    // MARK: - Voiced region detection

    /// Scans `audioURL` and returns a list of voiced regions. A region is a
    /// continuous span where the per-sample amplitude exceeds `threshold`,
    /// closed when the gap of below-threshold samples is longer than
    /// `minSilenceGap`. After raw detection, each span is expanded by
    /// `padding` seconds on each side (clamped to file bounds) and any
    /// resulting overlaps are merged. Spans shorter than `minRegionDuration`
    /// are discarded.
    static func detectVoicedRegions(
        audioURL: URL,
        threshold: Float = 0.01,
        minSilenceGap: Double = 0.6,
        padding: Double = 0.2,
        minRegionDuration: Double = 0.15
    ) async throws -> [VoicedRegion] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw TranscribeError.audioReadFailed(audioURL, underlying: error)
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalDuration = Double(file.length) / sampleRate
        let chunkFrames: AVAudioFrameCount = 65536

        var raw: [(Double, Double)] = []
        var spanStart: Double? = nil
        var lastVoicedTime: Double = 0
        var globalPos: AVAudioFramePosition = 0

        while globalPos < file.length {
            try Task.checkCancellation()
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            do { try file.read(into: buf, frameCount: chunkFrames) }
            catch { break }
            if buf.frameLength == 0 { break }

            if let channels = buf.floatChannelData {
                let frameCount = Int(buf.frameLength)
                for i in 0..<frameCount {
                    var maxAbs: Float = 0
                    for ch in 0..<channelCount {
                        let v = abs(channels[ch][i])
                        if v > maxAbs { maxAbs = v }
                    }
                    let t = Double(globalPos + AVAudioFramePosition(i)) / sampleRate
                    if maxAbs > threshold {
                        if spanStart == nil { spanStart = t }
                        lastVoicedTime = t
                    } else if let start = spanStart, t - lastVoicedTime > minSilenceGap {
                        raw.append((start, lastVoicedTime))
                        spanStart = nil
                    }
                }
            }
            globalPos += AVAudioFramePosition(buf.frameLength)
        }
        if let start = spanStart {
            raw.append((start, lastVoicedTime))
        }

        // Pad each span and merge overlaps.
        let padded: [(Double, Double)] = raw.map {
            (max(0, $0.0 - padding), min(totalDuration, $0.1 + padding))
        }
        var merged: [(Double, Double)] = []
        for span in padded.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, span.1))
            } else {
                merged.append(span)
            }
        }
        return merged
            .filter { $0.1 - $0.0 >= minRegionDuration }
            .map { VoicedRegion(fileStart: $0.0, fileEnd: $0.1) }
    }

    // MARK: - Logging

    private static let logger = Logger(subsystem: "MaycastStudio", category: "Transcription")

    private static func log(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.log(level: .info, "\(msg, privacy: .public)")
        print("[Transcription] \(msg)")
    }

    // MARK: - Result extraction

    private static func extractWordSegments(from result: SpeechTranscriber.Result) -> [TranscriptSegment] {
        let attributed = result.text
        var segments: [TranscriptSegment] = []
        var hadAttribute = false

        for (timeRangeOpt, runRange) in attributed.runs[\.audioTimeRange] {
            guard let timeRange = timeRangeOpt else { continue }
            let text = String(attributed[runRange].characters)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            segments.append(TranscriptSegment(
                start: timeRange.start.seconds,
                end: timeRange.end.seconds,
                text: trimmed
            ))
            hadAttribute = true
        }

        if !hadAttribute {
            let fullRange = attributed.startIndex..<attributed.endIndex
            let text = String(attributed[fullRange].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(TranscriptSegment(
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    text: text
                ))
            }
        }
        return segments
    }
}
