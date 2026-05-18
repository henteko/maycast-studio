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

        // `.volatileResults` makes the transcriber emit partial results as soon
        // as it recognises something — much better for streaming feedback than
        // waiting only for `isFinal` phrases.
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
        log("sourceFormat=\(sourceFormat) totalFrames=\(totalFrames) duration=\(Double(totalFrames) / sourceFormat.sampleRate)s")

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

        // Collect results in a child task. Track final segments separately;
        // accumulate the latest volatile prefix from the in-flight phrase so
        // the UI shows progress even when nothing is finalised yet.
        //
        // Volatile updates are throttled so we don't drown the MainActor in
        // re-renders — final results always emit immediately so the UI
        // doesn't lag behind the analyzer's "done" signal.
        let volatileThrottle: TimeInterval = 0.15
        let resultsTask = Task<[TranscriptSegment], Error> {
            var finalised: [TranscriptSegment] = []
            var lastVolatileEmit: Date = .distantPast
            var loggedFinalCount = 0
            for try await result in transcriber.results {
                let segs = extractWordSegments(from: result)
                if result.isFinal {
                    if !segs.isEmpty {
                        finalised.append(contentsOf: segs)
                        // Log time-alignment info for the first few finals.
                        if loggedFinalCount < 3 {
                            loggedFinalCount += 1
                            log("FINAL #\(loggedFinalCount) range=\(result.range.start.seconds)–\(result.range.end.seconds)s firstSegStart=\(segs.first?.start ?? -1)s text=\(segs.map(\.text).joined(separator: " "))")
                        } else {
                            log("FINAL +\(segs.count) total=\(finalised.count) range=\(result.range.start.seconds)–\(result.range.end.seconds)s text=\(segs.map(\.text).joined(separator: " "))")
                        }
                    } else {
                        log("FINAL (empty result) range=\(result.range.start.seconds)–\(result.range.end.seconds)s")
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
            // One last emit guarantees the UI's last-shown state matches the
            // final result, even if a volatile update was dropped by the throttle.
            emit(.segments(finalised))
            return finalised
        }

        emit(.status("Transcribing…"))

        // Stream-converter loop. We allocate an output buffer of analyzer-sized
        // chunks and let `AVAudioConverter` pull source frames via the input
        // closure as it needs them. This handles sample-rate-converter primer
        // latency correctly (the old "one source buffer, then endOfStream"
        // pattern produced zero output frames forever).
        let analyzerChunkFrames: AVAudioFrameCount = 8000   // ~0.5 s at 16 kHz
        let sourceReadFrames: AVAudioFrameCount = 4096
        var chunksFed = 0
        var emptyOutputs = 0
        var streamDone = false
        // Track cumulative analyzer-time so we can pass an explicit
        // presentation time to the analyzer (or at least log mismatches).
        var cumulativeAnalyzerFrames: Int64 = 0
        let analyzerSampleRate = analyzerFormat.sampleRate

        while !streamDone {
            try Task.checkCancellation()

            guard let outBuf = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: analyzerChunkFrames) else {
                inputContinuation.finish()
                throw TranscribeError.bufferAllocationFailed
            }

            var convError: NSError?
            let status: AVAudioConverterOutputStatus

            if let conv = converter {
                status = conv.convert(to: outBuf, error: &convError) { _, statusOut in
                    guard let sourceBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceReadFrames) else {
                        statusOut.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try audioFile.read(into: sourceBuf, frameCount: sourceReadFrames)
                    } catch {
                        statusOut.pointee = .endOfStream
                        return nil
                    }
                    if sourceBuf.frameLength == 0 {
                        statusOut.pointee = .endOfStream
                        return nil
                    }
                    statusOut.pointee = .haveData
                    return sourceBuf
                }
            } else {
                // No conversion needed: read directly into the analyzer buffer.
                do {
                    try audioFile.read(into: outBuf, frameCount: analyzerChunkFrames)
                } catch {
                    inputContinuation.finish()
                    throw TranscribeError.audioReadFailed(audioURL, underlying: error)
                }
                status = outBuf.frameLength == 0 ? .endOfStream : .haveData
            }

            if let convError {
                inputContinuation.finish()
                throw TranscribeError.streamFailed("Audio conversion failed: \(convError)")
            }
            if status == .error {
                inputContinuation.finish()
                throw TranscribeError.streamFailed("Converter reported .error status")
            }

            if outBuf.frameLength > 0 {
                let presentationTime = CMTime(
                    value: cumulativeAnalyzerFrames,
                    timescale: Int32(analyzerSampleRate)
                )
                // Pass the explicit audio time so the analyzer doesn't VAD-shift
                // its result timestamps when the buffer contains silence.
                inputContinuation.yield(AnalyzerInput(buffer: outBuf, bufferStartTime: presentationTime))
                chunksFed += 1
                cumulativeAnalyzerFrames += Int64(outBuf.frameLength)
                if chunksFed <= 3 || chunksFed % 100 == 0 {
                    let nowSeconds = Double(cumulativeAnalyzerFrames) / analyzerSampleRate
                    log("fed chunk #\(chunksFed) prevPresentationTime=\(presentationTime.seconds)s cumulativeOutTime=\(nowSeconds)s (len=\(outBuf.frameLength), status=\(status.rawValue))")
                }
            } else {
                emptyOutputs += 1
                if emptyOutputs <= 5 {
                    log("converter returned empty buffer (status=\(status.rawValue))")
                }
            }

            if status == .endOfStream {
                streamDone = true
            }
        }
        log("fed \(chunksFed) chunks (emptyOutputs=\(emptyOutputs)); closing input")

        inputContinuation.finish()
        emit(.status("Finalising…"))

        // Wait for analyzer.start to return (it consumes the stream and exits).
        do {
            try await analyzerJob
            log("analyzerJob complete")
        } catch {
            log("analyzerJob threw: \(error)")
        }

        // Flush any volatile/in-flight phrases into `.isFinal` results. We
        // back off the requested time by a small margin so the analyzer
        // doesn't wait for input past the actual end of fed audio.
        let totalDuration = Double(audioFile.length) / sourceFormat.sampleRate
        let endTime = CMTime(
            seconds: max(0, totalDuration - 0.05),
            preferredTimescale: 1000
        )
        do {
            log("finalizeAndFinish through=\(endTime.seconds)s")
            try await analyzer.finalizeAndFinish(through: endTime)
            log("finalize complete")
        } catch {
            log("finalize threw: \(error)")
        }

        log("awaiting resultsTask…")
        _ = try? await resultsTask.value
        log("done")
    }

    /// Unified-logging output so progress is visible in Xcode's debug console
    /// even under App Sandbox (where stderr is not captured by the debugger).
    /// Also visible in Console.app filtered on subsystem "MaycastStudio".
    private static let logger = Logger(subsystem: "MaycastStudio", category: "Transcription")

    private static func log(_ message: @autoclosure () -> String) {
        let msg = message()
        // `\(_, privacy: .public)` keeps the message visible in Console.app
        // without privacy redaction.
        logger.log(level: .info, "\(msg, privacy: .public)")
        // Also mirror to stdout so `print` shows in Xcode debug console even
        // when unified logging is filtered.
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
