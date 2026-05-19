import Foundation
import AVFoundation
import Accelerate

// MARK: - AudioBuffer

/// PCM audio in planar (non-interleaved) Float32 form.
///
/// `samples[channel][frame]`. All operations in MaycastCore assume this layout.
public struct AudioBuffer: Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [[Float]]

    public var frameCount: Int { samples.first?.count ?? 0 }
    public var duration: TimeInterval { Double(frameCount) / sampleRate }

    public init(sampleRate: Double, channelCount: Int, samples: [[Float]]) {
        precondition(samples.count == channelCount, "samples.count must equal channelCount")
        if let head = samples.first {
            for ch in samples { precondition(ch.count == head.count, "all channels must have equal frame count") }
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }
}

// MARK: - AudioIO

public enum AudioIO {
    /// Read an audio file in any AVFoundation-supported format (WAV, AIFF, MP3, M4A, FLAC, ...)
    /// into a planar Float32 `AudioBuffer`.
    public static func read(from url: URL) throws -> AudioBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MaycastError.audioReadFailed(url, underlying: error)
        }

        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        // Always read into a planar Float32 buffer for downstream DSP simplicity.
        guard let planarFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: planarFormat, frameCapacity: frameCount)
        else {
            throw MaycastError.audioReadFailed(url, underlying: NSError(
                domain: "MaycastCore.AudioIO",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate buffer"]
            ))
        }

        // If the file's processingFormat already matches our target, read directly;
        // otherwise route through an AVAudioConverter.
        if sourceFormat == planarFormat {
            do {
                try file.read(into: pcmBuffer)
            } catch {
                throw MaycastError.audioReadFailed(url, underlying: error)
            }
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: planarFormat),
                  let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
            else {
                throw MaycastError.audioReadFailed(url, underlying: NSError(
                    domain: "MaycastCore.AudioIO",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to set up converter"]
                ))
            }
            do {
                try file.read(into: sourceBuffer)
            } catch {
                throw MaycastError.audioReadFailed(url, underlying: error)
            }
            var convError: NSError?
            converter.convert(to: pcmBuffer, error: &convError) { _, status in
                status.pointee = .haveData
                return sourceBuffer
            }
            if let convError {
                throw MaycastError.audioReadFailed(url, underlying: convError)
            }
        }

        guard let channelData = pcmBuffer.floatChannelData else {
            throw MaycastError.audioReadFailed(url, underlying: NSError(
                domain: "MaycastCore.AudioIO",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "floatChannelData unavailable"]
            ))
        }

        let channelCount = Int(planarFormat.channelCount)
        let frames = Int(pcmBuffer.frameLength)
        var samples: [[Float]] = []
        samples.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            let ptr = UnsafeBufferPointer(start: channelData[ch], count: frames)
            samples.append(Array(ptr))
        }

        return AudioBuffer(
            sampleRate: planarFormat.sampleRate,
            channelCount: channelCount,
            samples: samples
        )
    }

    /// Write an `AudioBuffer` to disk as a 16-bit PCM WAV file.
    public static func writeWAV(_ buffer: AudioBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: buffer.sampleRate,
            AVNumberOfChannelsKey: buffer.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MaycastError.audioWriteFailed(url, underlying: error)
        }

        let processingFormat = file.processingFormat
        let frames = AVAudioFrameCount(buffer.frameCount)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: max(frames, 1)) else {
            throw MaycastError.audioWriteFailed(url, underlying: NSError(
                domain: "MaycastCore.AudioIO",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate buffer"]
            ))
        }
        pcmBuffer.frameLength = frames

        guard let channelData = pcmBuffer.floatChannelData else {
            throw MaycastError.audioWriteFailed(url, underlying: NSError(
                domain: "MaycastCore.AudioIO",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "floatChannelData unavailable"]
            ))
        }

        for ch in 0..<buffer.channelCount {
            buffer.samples[ch].withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channelData[ch].update(from: base, count: buffer.frameCount)
                }
            }
        }

        do {
            try file.write(from: pcmBuffer)
        } catch {
            throw MaycastError.audioWriteFailed(url, underlying: error)
        }
    }

    /// Transcode any AVFoundation-supported source (WAV / AIFF / MP3 / M4A /
    /// AAC / FLAC …) directly to a 16-bit Linear PCM WAVE file by spawning
    /// `/usr/bin/afconvert`. Compared to `read` + `writeWAV` this skips:
    ///
    /// 1. The full-file decode into an in-memory `AVAudioPCMBuffer`
    /// 2. The Swift `[[Float]]` planar copy in `AudioBuffer`
    /// 3. The re-allocation of a destination `AVAudioPCMBuffer` for write
    ///
    /// CoreAudio streams the conversion chunk-by-chunk inside the subprocess,
    /// which is roughly an order of magnitude faster than the round-trip path
    /// for typical podcast-length recordings.
    ///
    /// Sample rate and channel layout are preserved from the source. The
    /// destination's parent directory is created and any existing file at the
    /// destination is removed first.
    public static func transcodeToWAV(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-d", "LEI16",          // Linear PCM, little-endian, integer, 16-bit; sample rate inherited from source
            "-f", "WAVE",
            sourceURL.path,
            destinationURL.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw MaycastError.audioWriteFailed(destinationURL, underlying: error)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errText = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw MaycastError.audioWriteFailed(destinationURL, underlying: NSError(
                domain: "MaycastCore.AudioIO.afconvert",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "afconvert exit \(process.terminationStatus): \(errText)"]
            ))
        }
    }

    /// Return the duration of an audio file using AVAudioFile metadata only —
    /// no PCM frames are decoded. Useful when callers need just the length
    /// (e.g. to seed an `arrangement.json`) without paying for a full decode.
    public static func probeDuration(of url: URL) throws -> TimeInterval {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MaycastError.audioReadFailed(url, underlying: error)
        }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return 0 }
        return TimeInterval(file.length) / sr
    }

    // MARK: - Helpers

    /// Generate a silent buffer.
    public static func silence(
        duration: TimeInterval,
        sampleRate: Double = 48000,
        channelCount: Int = 1
    ) -> AudioBuffer {
        let frames = max(0, Int(duration * sampleRate))
        let channel = Array(repeating: Float(0), count: frames)
        return AudioBuffer(
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: Array(repeating: channel, count: channelCount)
        )
    }

    /// Generate a sine wave (useful for tests).
    public static func sineWave(
        frequency: Double,
        duration: TimeInterval,
        amplitude: Float = 0.5,
        sampleRate: Double = 48000,
        channelCount: Int = 1
    ) -> AudioBuffer {
        let frames = max(0, Int(duration * sampleRate))
        var samples = [Float](repeating: 0, count: frames)
        let twoPiF = 2.0 * .pi * frequency
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            samples[i] = amplitude * Float(sin(twoPiF * t))
        }
        return AudioBuffer(
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: Array(repeating: samples, count: channelCount)
        )
    }

    /// Render a clip arrangement against a source `AudioBuffer`.
    ///
    /// Each clip extracts `[sourceStart, sourceEnd)` from `source` and places it
    /// at `timelineStart` on the output timeline. Regions not covered by any
    /// clip render as silence (no ripple — see roadmap §1.2 decision #3).
    public static func render(arrangement: Arrangement, from source: AudioBuffer) -> AudioBuffer {
        let sampleRate = source.sampleRate
        let channelCount = source.channelCount
        let totalFrames = max(0, Int((arrangement.totalDuration * sampleRate).rounded()))
        let sourceFrames = source.samples.first?.count ?? 0
        var output: [[Float]] = Array(
            repeating: Array(repeating: 0, count: totalFrames),
            count: channelCount
        )
        let floatSize = MemoryLayout<Float>.size
        for clip in arrangement.clips {
            let srcStart = max(0, Int((clip.sourceStart * sampleRate).rounded()))
            let srcEnd = min(sourceFrames, Int((clip.sourceEnd * sampleRate).rounded()))
            let dstStart = max(0, Int((clip.timelineStart * sampleRate).rounded()))
            let copyFrames = max(0, min(srcEnd - srcStart, totalFrames - dstStart))
            guard copyFrames > 0 else { continue }
            // Bulk-copy each channel via `memcpy` instead of a per-sample Swift
            // loop. On a 30-min stereo episode this drops the inner loop from
            // ~3 seconds to a few hundred milliseconds — the dominant cost in
            // Slice apply used to be this copy.
            for ch in 0..<channelCount {
                source.samples[ch].withUnsafeBufferPointer { srcBP in
                    output[ch].withUnsafeMutableBufferPointer { dstBP in
                        guard let srcBase = srcBP.baseAddress,
                              let dstBase = dstBP.baseAddress
                        else { return }
                        memcpy(
                            dstBase.advanced(by: dstStart),
                            srcBase.advanced(by: srcStart),
                            copyFrames * floatSize
                        )
                    }
                }
            }
        }
        return AudioBuffer(sampleRate: sampleRate, channelCount: channelCount, samples: output)
    }

    /// Compose a final episode mix: voice master (typically the result of
    /// `mixParallel`) with optional Intro and Outro pieces that overlap with
    /// the voice and duck during the overlap region.
    ///
    /// Timeline (matching the maycast-polish reference behavior):
    /// ```
    /// 0 ............... introDur ............... outroStart ..... outroEnd
    /// [intro] —ramp↓— [duck level] (continues during voice overlap)
    ///        masterStart ════════════════════════ voiceEnd
    ///                       [duck level] —ramp↑— [outro full]
    /// ```
    /// - `masterStart = introDur - introOffset` (0 if no intro)
    /// - `outroStart  = masterStart + voiceDur - outroOffset` (no outro overlap if no outro)
    /// - Intro is at full volume up to `introDur - introOffset - fade/2`, ramps
    ///   linearly down to `duckAmp = 10^(duckingGainDB/20)` over `duckingFadeSec`.
    /// - Outro starts at `outroStart` at `duckAmp`, ramps linearly up to full at
    ///   `outroOffset` seconds into the outro, stays full until its end.
    ///
    /// All inputs must share the same sample rate (throws otherwise). The
    /// output is always stereo: mono inputs are split into both channels.
    public static func composeFinalMix(
        voiceMaster: AudioBuffer,
        intro: AudioBuffer? = nil,
        outro: AudioBuffer? = nil,
        introOffsetSec: Double = 2.0,
        outroOffsetSec: Double = 5.0,
        duckingGainDB: Double = -12,
        duckingFadeSec: Double = 0.5
    ) throws -> AudioBuffer {
        let sr = voiceMaster.sampleRate
        // Auto-resample intro / outro if they don't match the voice master's
        // sample rate (common when the assets are MP3s at 44.1 kHz and the
        // voice tracks are 48 kHz Maycast WAVs).
        let intro = try intro.map { $0.sampleRate == sr ? $0 : try resample($0, to: sr) }
        let outro = try outro.map { $0.sampleRate == sr ? $0 : try resample($0, to: sr) }

        let voiceDur = voiceMaster.duration
        let introDur = intro?.duration ?? 0
        let outroDur = outro?.duration ?? 0

        // Clamp offsets to the available piece duration.
        let introOffset = max(0, min(introOffsetSec, introDur))
        let outroOffset = max(0, min(outroOffsetSec, outroDur))

        let masterStart = max(0, introDur - introOffset)
        let masterEnd = masterStart + voiceDur
        let outroStart = max(0, masterEnd - outroOffset)
        let totalDur = max(masterEnd, outroStart + outroDur)

        let totalFrames = Int((totalDur * sr).rounded())
        var left = [Float](repeating: 0, count: totalFrames)
        var right = [Float](repeating: 0, count: totalFrames)

        // 1) Voice master at masterStart (constant unity gain).
        addStereo(
            buffer: voiceMaster,
            into: &left, &right,
            atFrameOffset: Int((masterStart * sr).rounded()),
            envelope: nil
        )

        // 2) Intro at t=0 with rampDown at `introDur - introOffset`.
        if let intro {
            let envelope = makeRampDownEnvelope(
                frameCount: intro.frameCount,
                sampleRate: sr,
                duckStart: introDur - introOffset,
                fadeSec: duckingFadeSec,
                duckAmp: pow(10.0, duckingGainDB / 20.0)
            )
            addStereo(
                buffer: intro,
                into: &left, &right,
                atFrameOffset: 0,
                envelope: envelope
            )
        }

        // 3) Outro at outroStart with rampUp at `outroOffset` into the file.
        if let outro {
            let envelope = makeRampUpEnvelope(
                frameCount: outro.frameCount,
                sampleRate: sr,
                duckEnd: outroOffset,
                fadeSec: duckingFadeSec,
                duckAmp: pow(10.0, duckingGainDB / 20.0)
            )
            addStereo(
                buffer: outro,
                into: &left, &right,
                atFrameOffset: Int((outroStart * sr).rounded()),
                envelope: envelope
            )
        }

        // Final clip to [-1, 1] in-place with vDSP.
        if totalFrames > 0 {
            var lower: Float = -1
            var upper: Float = 1
            let n = vDSP_Length(totalFrames)
            left.withUnsafeMutableBufferPointer { bp in
                if let base = bp.baseAddress {
                    vDSP_vclip(base, 1, &lower, &upper, base, 1, n)
                }
            }
            right.withUnsafeMutableBufferPointer { bp in
                if let base = bp.baseAddress {
                    vDSP_vclip(base, 1, &lower, &upper, base, 1, n)
                }
            }
        }
        return AudioBuffer(sampleRate: sr, channelCount: 2, samples: [left, right])
    }

    /// Mix multiple buffers in parallel (sample-wise sum). All inputs must share
    /// the same sample rate. Mono inputs are routed to both output channels; the
    /// output is always stereo. The mix is clipped to `[-1, 1]` to avoid wrap.
    ///
    /// Phase 1.3 basic mix: no gain staging or per-track levels. Intro / Outro /
    /// BGM ducking come in Phase 3.
    public static func mixParallel(_ buffers: [AudioBuffer]) throws -> AudioBuffer {
        guard let first = buffers.first else {
            return AudioBuffer(sampleRate: 48000, channelCount: 2, samples: [[], []])
        }
        for b in buffers.dropFirst() {
            if b.sampleRate != first.sampleRate {
                throw MaycastError.audioFormatMismatch(
                    expected: "sampleRate=\(first.sampleRate)",
                    actual: "sampleRate=\(b.sampleRate)"
                )
            }
        }
        let sampleRate = first.sampleRate
        let outputFrames = buffers.map(\.frameCount).max() ?? 0
        var left = [Float](repeating: 0, count: outputFrames)
        var right = [Float](repeating: 0, count: outputFrames)

        for b in buffers {
            let frames = b.frameCount
            if b.channelCount == 0 || frames == 0 { continue }
            let n = vDSP_Length(frames)
            // Add this track's first channel to the left accumulator.
            // For mono inputs we also broadcast to the right channel.
            b.samples[0].withUnsafeBufferPointer { srcBP in
                guard let srcBase = srcBP.baseAddress else { return }
                left.withUnsafeMutableBufferPointer { lBP in
                    if let dst = lBP.baseAddress {
                        vDSP_vadd(srcBase, 1, dst, 1, dst, 1, n)
                    }
                }
                if b.channelCount == 1 {
                    right.withUnsafeMutableBufferPointer { rBP in
                        if let dst = rBP.baseAddress {
                            vDSP_vadd(srcBase, 1, dst, 1, dst, 1, n)
                        }
                    }
                }
            }
            if b.channelCount >= 2 {
                b.samples[1].withUnsafeBufferPointer { srcBP in
                    guard let srcBase = srcBP.baseAddress else { return }
                    right.withUnsafeMutableBufferPointer { rBP in
                        if let dst = rBP.baseAddress {
                            vDSP_vadd(srcBase, 1, dst, 1, dst, 1, n)
                        }
                    }
                }
            }
        }

        // Clip to [-1, 1] in-place via vDSP. Faster than a per-sample if-else
        // and matches the same numerical result.
        if outputFrames > 0 {
            var lower: Float = -1
            var upper: Float = 1
            let n = vDSP_Length(outputFrames)
            left.withUnsafeMutableBufferPointer { bp in
                if let base = bp.baseAddress {
                    vDSP_vclip(base, 1, &lower, &upper, base, 1, n)
                }
            }
            right.withUnsafeMutableBufferPointer { bp in
                if let base = bp.baseAddress {
                    vDSP_vclip(base, 1, &lower, &upper, base, 1, n)
                }
            }
        }

        return AudioBuffer(sampleRate: sampleRate, channelCount: 2, samples: [left, right])
    }

    // MARK: - composeFinalMix helpers

    /// Add `buffer` into the stereo `left` / `right` accumulators starting at
    /// `atFrameOffset`. Mono inputs are routed to both channels.
    ///
    /// If `envelope` is supplied (same length as the buffer's frame count), it
    /// is interpreted as a per-sample gain — `dst[i] += src[i] * env[i]` via
    /// `vDSP_vma`. Otherwise the buffer is added as-is with `vDSP_vadd`.
    fileprivate static func addStereo(
        buffer: AudioBuffer,
        into left: inout [Float], _ right: inout [Float],
        atFrameOffset offset: Int,
        envelope: [Float]?
    ) {
        let outFrames = left.count
        let copy = min(buffer.frameCount, outFrames - offset)
        guard copy > 0 else { return }
        let n = vDSP_Length(copy)
        let mono = buffer.channelCount == 1

        addChannel(
            source: buffer.samples[0], offset: 0, length: copy,
            into: &left, atOffset: offset, envelope: envelope, envelopeOffset: 0, n: n
        )
        if mono {
            addChannel(
                source: buffer.samples[0], offset: 0, length: copy,
                into: &right, atOffset: offset, envelope: envelope, envelopeOffset: 0, n: n
            )
        } else {
            addChannel(
                source: buffer.samples[1], offset: 0, length: copy,
                into: &right, atOffset: offset, envelope: envelope, envelopeOffset: 0, n: n
            )
        }
    }

    /// Either `dst[off..off+n] += src` (no envelope) or `dst += src * env`
    /// (with envelope). Routed through Accelerate so a 30-min stereo mix
    /// finishes in tens of milliseconds rather than seconds.
    private static func addChannel(
        source: [Float],
        offset srcOffset: Int,
        length: Int,
        into dst: inout [Float],
        atOffset dstOffset: Int,
        envelope: [Float]?,
        envelopeOffset: Int,
        n: vDSP_Length
    ) {
        source.withUnsafeBufferPointer { srcBP in
            dst.withUnsafeMutableBufferPointer { dstBP in
                guard let srcBase = srcBP.baseAddress,
                      let dstBase = dstBP.baseAddress else { return }
                let src = srcBase.advanced(by: srcOffset)
                let dstPtr = dstBase.advanced(by: dstOffset)
                if let envelope {
                    envelope.withUnsafeBufferPointer { envBP in
                        if let envBase = envBP.baseAddress {
                            // dst[i] = src[i] * env[i] + dst[i]
                            vDSP_vma(
                                src, 1,
                                envBase.advanced(by: envelopeOffset), 1,
                                dstPtr, 1,
                                dstPtr, 1,
                                n
                            )
                        }
                    }
                } else {
                    // dst[i] = src[i] + dst[i]
                    vDSP_vadd(src, 1, dstPtr, 1, dstPtr, 1, n)
                }
            }
        }
    }

    /// Build a per-sample envelope that goes 1.0 → `duckAmp` with a linear
    /// transition centered at `duckStart` seconds (width = `fadeSec`).
    /// Three flat / ramp / flat segments are filled directly so we never
    /// evaluate a `Double → Float` curve in a sample-rate loop.
    fileprivate static func makeRampDownEnvelope(
        frameCount: Int,
        sampleRate: Double,
        duckStart: Double,
        fadeSec: Double,
        duckAmp: Double
    ) -> [Float] {
        var env = [Float](repeating: 1.0, count: frameCount)
        guard frameCount > 0 else { return env }
        let rampStart = duckStart - fadeSec / 2
        let rampEnd = duckStart + fadeSec / 2
        let rampStartFrame = max(0, min(frameCount, Int((rampStart * sampleRate).rounded())))
        let rampEndFrame = max(rampStartFrame, min(frameCount, Int((rampEnd * sampleRate).rounded())))
        // Ramp segment: linear from 1 to duckAmp.
        if rampEndFrame > rampStartFrame, fadeSec > 0 {
            for i in rampStartFrame..<rampEndFrame {
                let progress = Double(i - rampStartFrame) / Double(rampEndFrame - rampStartFrame)
                env[i] = Float(1.0 + (duckAmp - 1.0) * progress)
            }
        }
        // Tail segment: held at duckAmp.
        let tailStart = fadeSec > 0 ? rampEndFrame : max(0, min(frameCount, Int((duckStart * sampleRate).rounded())))
        if tailStart < frameCount {
            for i in tailStart..<frameCount { env[i] = Float(duckAmp) }
        }
        return env
    }

    /// Build a per-sample envelope that goes `duckAmp` → 1.0 with a linear
    /// transition centered at `duckEnd` seconds.
    fileprivate static func makeRampUpEnvelope(
        frameCount: Int,
        sampleRate: Double,
        duckEnd: Double,
        fadeSec: Double,
        duckAmp: Double
    ) -> [Float] {
        var env = [Float](repeating: 1.0, count: frameCount)
        guard frameCount > 0 else { return env }
        let rampStart = duckEnd - fadeSec / 2
        let rampEnd = duckEnd + fadeSec / 2
        let rampStartFrame = max(0, min(frameCount, Int((rampStart * sampleRate).rounded())))
        let rampEndFrame = max(rampStartFrame, min(frameCount, Int((rampEnd * sampleRate).rounded())))
        // Lead segment: held at duckAmp.
        let leadEnd = fadeSec > 0 ? rampStartFrame : max(0, min(frameCount, Int((duckEnd * sampleRate).rounded())))
        for i in 0..<leadEnd { env[i] = Float(duckAmp) }
        // Ramp segment.
        if rampEndFrame > rampStartFrame, fadeSec > 0 {
            for i in rampStartFrame..<rampEndFrame {
                let progress = Double(i - rampStartFrame) / Double(rampEndFrame - rampStartFrame)
                env[i] = Float(duckAmp + (1.0 - duckAmp) * progress)
            }
        }
        // Tail (after ramp) already 1.0 from init.
        return env
    }

    /// Read a sub-range of an audio file directly, without loading the entire
    /// file first. Useful for the Mix overlap preview: only the few seconds at
    /// each end need to come off disk.
    ///
    /// The returned buffer is in planar Float32, same channel count as the
    /// source file. `startSec`/`endSec` are clamped to the file's bounds.
    public static func readRange(from url: URL, startSec: Double, endSec: Double) throws -> AudioBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MaycastError.audioReadFailed(url, underlying: error)
        }
        let sourceFormat = file.processingFormat
        let totalFrames = file.length

        let clampedStart = max(0, min(Double(totalFrames) / sourceFormat.sampleRate, startSec))
        let clampedEnd = max(clampedStart, min(Double(totalFrames) / sourceFormat.sampleRate, endSec))
        let startFrame = AVAudioFramePosition(clampedStart * sourceFormat.sampleRate)
        let endFrame = AVAudioFramePosition(clampedEnd * sourceFormat.sampleRate)
        let wantedFrames = AVAudioFrameCount(max(0, endFrame - startFrame))

        guard let planarFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(pcmFormat: planarFormat, frameCapacity: max(1, wantedFrames))
        else {
            throw MaycastError.audioReadFailed(url, underlying: NSError(
                domain: "MaycastCore.AudioIO",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate buffer"]
            ))
        }
        if wantedFrames == 0 {
            return AudioBuffer(
                sampleRate: sourceFormat.sampleRate,
                channelCount: Int(sourceFormat.channelCount),
                samples: Array(repeating: [], count: Int(sourceFormat.channelCount))
            )
        }

        do {
            file.framePosition = startFrame
            if sourceFormat == planarFormat {
                try file.read(into: buffer, frameCount: wantedFrames)
            } else {
                // Convert via AVAudioConverter for non-planar / non-float files.
                let converter = AVAudioConverter(from: sourceFormat, to: planarFormat)
                guard let converter else {
                    throw MaycastError.audioReadFailed(url, underlying: NSError(
                        domain: "MaycastCore.AudioIO",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No converter to planar float"]
                    ))
                }
                guard let scratch = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: wantedFrames) else {
                    throw MaycastError.audioReadFailed(url, underlying: NSError(
                        domain: "MaycastCore.AudioIO",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to allocate scratch buffer"]
                    ))
                }
                try file.read(into: scratch, frameCount: wantedFrames)
                var error: NSError?
                let status = converter.convert(to: buffer, error: &error) { _, statusOut in
                    statusOut.pointee = .haveData
                    return scratch
                }
                if status == .error || error != nil {
                    throw MaycastError.audioReadFailed(url, underlying: error ?? NSError(
                        domain: "MaycastCore.AudioIO",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Converter failed"]
                    ))
                }
            }
        } catch let err as MaycastError {
            throw err
        } catch {
            throw MaycastError.audioReadFailed(url, underlying: error)
        }

        let chCount = Int(planarFormat.channelCount)
        var samples = [[Float]](repeating: [], count: chCount)
        let n = Int(buffer.frameLength)
        if let channels = buffer.floatChannelData {
            for ch in 0..<chCount {
                samples[ch] = Array(UnsafeBufferPointer(start: channels[ch], count: n))
            }
        }
        return AudioBuffer(
            sampleRate: planarFormat.sampleRate,
            channelCount: chCount,
            samples: samples
        )
    }

    /// In-memory slice of an existing `AudioBuffer`. `startSec`/`endSec` are
    /// clamped to the buffer's bounds.
    /// Resample `buffer` to `targetRate` using `AVAudioConverter`. Returns the
    /// input unchanged if it already matches. Used by `composeFinalMix` to
    /// align intro / outro assets to the voice master's sample rate.
    public static func resample(_ buffer: AudioBuffer, to targetRate: Double) throws -> AudioBuffer {
        guard buffer.sampleRate != targetRate else { return buffer }
        guard buffer.frameCount > 0 else {
            return AudioBuffer(
                sampleRate: targetRate,
                channelCount: buffer.channelCount,
                samples: Array(repeating: [], count: buffer.channelCount)
            )
        }
        guard let srcFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.sampleRate,
            channels: AVAudioChannelCount(buffer.channelCount),
            interleaved: false
        ),
              let dstFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetRate,
                channels: AVAudioChannelCount(buffer.channelCount),
                interleaved: false
              ),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else {
            throw MaycastError.audioFormatMismatch(
                expected: "sampleRate=\(targetRate)",
                actual: "sampleRate=\(buffer.sampleRate) (no converter)"
            )
        }
        // Pack the planar Float32 source into an AVAudioPCMBuffer.
        guard let srcBuf = AVAudioPCMBuffer(
            pcmFormat: srcFormat,
            frameCapacity: AVAudioFrameCount(buffer.frameCount)
        ) else {
            throw MaycastError.audioFormatMismatch(
                expected: "sampleRate=\(targetRate)",
                actual: "could not allocate src buffer"
            )
        }
        srcBuf.frameLength = AVAudioFrameCount(buffer.frameCount)
        if let channels = srcBuf.floatChannelData {
            for ch in 0..<buffer.channelCount {
                buffer.samples[ch].withUnsafeBufferPointer { bp in
                    channels[ch].update(from: bp.baseAddress!, count: buffer.frameCount)
                }
            }
        }

        let ratio = targetRate / buffer.sampleRate
        let dstCapacity = AVAudioFrameCount((Double(buffer.frameCount) * ratio).rounded(.up) + 64)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            throw MaycastError.audioFormatMismatch(
                expected: "sampleRate=\(targetRate)",
                actual: "could not allocate dst buffer"
            )
        }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: dstBuf, error: &error) { _, statusPtr in
            if fed {
                statusPtr.pointee = .endOfStream
                return nil
            }
            fed = true
            statusPtr.pointee = .haveData
            return srcBuf
        }
        if let error { throw MaycastError.audioReadFailed(URL(fileURLWithPath: "/"), underlying: error) }
        if status == .error {
            throw MaycastError.audioFormatMismatch(
                expected: "sampleRate=\(targetRate)",
                actual: "AVAudioConverter status=.error"
            )
        }

        let outFrames = Int(dstBuf.frameLength)
        var outSamples = [[Float]](repeating: [], count: buffer.channelCount)
        if let channels = dstBuf.floatChannelData {
            for ch in 0..<buffer.channelCount {
                outSamples[ch] = Array(UnsafeBufferPointer(start: channels[ch], count: outFrames))
            }
        }
        return AudioBuffer(
            sampleRate: targetRate,
            channelCount: buffer.channelCount,
            samples: outSamples
        )
    }

    public static func slice(_ buffer: AudioBuffer, from startSec: Double, to endSec: Double) -> AudioBuffer {
        guard buffer.frameCount > 0 else { return buffer }
        let sr = buffer.sampleRate
        let totalDur = buffer.duration
        let s = max(0, min(totalDur, startSec))
        let e = max(s, min(totalDur, endSec))
        let startFrame = Int((s * sr).rounded())
        let endFrame = min(buffer.frameCount, Int((e * sr).rounded()))
        let sliced = buffer.samples.map { Array($0[startFrame..<endFrame]) }
        return AudioBuffer(sampleRate: sr, channelCount: buffer.channelCount, samples: sliced)
    }

    /// Concatenate buffers head-to-tail. All inputs must share sample rate and channel count.
    public static func concat(_ buffers: [AudioBuffer]) throws -> AudioBuffer {
        guard let first = buffers.first else {
            return silence(duration: 0)
        }
        for b in buffers.dropFirst() {
            if b.sampleRate != first.sampleRate || b.channelCount != first.channelCount {
                throw MaycastError.audioFormatMismatch(
                    expected: "sampleRate=\(first.sampleRate), channels=\(first.channelCount)",
                    actual: "sampleRate=\(b.sampleRate), channels=\(b.channelCount)"
                )
            }
        }
        var combined: [[Float]] = Array(repeating: [], count: first.channelCount)
        let totalFrames = buffers.reduce(0) { $0 + $1.frameCount }
        for ch in 0..<first.channelCount {
            combined[ch].reserveCapacity(totalFrames)
            for b in buffers {
                combined[ch].append(contentsOf: b.samples[ch])
            }
        }
        return AudioBuffer(
            sampleRate: first.sampleRate,
            channelCount: first.channelCount,
            samples: combined
        )
    }
}
