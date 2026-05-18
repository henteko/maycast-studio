import Foundation
import AVFoundation

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
        for clip in arrangement.clips {
            let srcStart = max(0, Int((clip.sourceStart * sampleRate).rounded()))
            let srcEnd = min(sourceFrames, Int((clip.sourceEnd * sampleRate).rounded()))
            let dstStart = max(0, Int((clip.timelineStart * sampleRate).rounded()))
            let copyFrames = max(0, min(srcEnd - srcStart, totalFrames - dstStart))
            guard copyFrames > 0 else { continue }
            for ch in 0..<channelCount {
                for i in 0..<copyFrames {
                    output[ch][dstStart + i] = source.samples[ch][srcStart + i]
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

        // 1) Voice master at masterStart.
        addStereo(
            buffer: voiceMaster,
            into: &left, &right,
            atFrameOffset: Int((masterStart * sr).rounded()),
            gain: 1.0
        )

        // 2) Intro at t=0 with rampDown at `introDur - introOffset`.
        if let intro {
            let duckStart = introDur - introOffset
            addStereo(
                buffer: intro,
                into: &left, &right,
                atFrameOffset: 0,
                gainAtFileTime: { localTime in
                    rampDown(
                        at: localTime,
                        duckStart: duckStart,
                        fadeSec: duckingFadeSec,
                        duckAmp: pow(10.0, duckingGainDB / 20.0)
                    )
                }
            )
        }

        // 3) Outro at outroStart with rampUp at `outroOffset` into the file.
        if let outro {
            addStereo(
                buffer: outro,
                into: &left, &right,
                atFrameOffset: Int((outroStart * sr).rounded()),
                gainAtFileTime: { localTime in
                    rampUp(
                        at: localTime,
                        duckEnd: outroOffset,
                        fadeSec: duckingFadeSec,
                        duckAmp: pow(10.0, duckingGainDB / 20.0)
                    )
                }
            )
        }

        // Clip.
        for i in 0..<totalFrames {
            if left[i] > 1 { left[i] = 1 } else if left[i] < -1 { left[i] = -1 }
            if right[i] > 1 { right[i] = 1 } else if right[i] < -1 { right[i] = -1 }
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
            switch b.channelCount {
            case 0:
                continue
            case 1:
                for i in 0..<frames {
                    let s = b.samples[0][i]
                    left[i] += s
                    right[i] += s
                }
            default:
                // Stereo (or higher: take the first two channels)
                for i in 0..<frames {
                    left[i] += b.samples[0][i]
                    right[i] += b.samples[1][i]
                }
            }
        }

        for i in 0..<outputFrames {
            if left[i] > 1 { left[i] = 1 } else if left[i] < -1 { left[i] = -1 }
            if right[i] > 1 { right[i] = 1 } else if right[i] < -1 { right[i] = -1 }
        }

        return AudioBuffer(sampleRate: sampleRate, channelCount: 2, samples: [left, right])
    }

    // MARK: - composeFinalMix helpers

    /// Add `buffer` into the stereo `left` / `right` accumulators starting at
    /// `atFrameOffset`. Mono inputs are routed to both channels.
    /// If `gainAtFileTime` is supplied it is sampled per output frame (in the
    /// source buffer's time domain) and used as a multiplicative gain; this is
    /// how the rampDown / rampUp envelopes for intro/outro ducking are
    /// applied.
    fileprivate static func addStereo(
        buffer: AudioBuffer,
        into left: inout [Float], _ right: inout [Float],
        atFrameOffset offset: Int,
        gain: Float = 1.0,
        gainAtFileTime: ((Double) -> Float)? = nil
    ) {
        let sr = buffer.sampleRate
        let outFrames = left.count
        let copy = min(buffer.frameCount, outFrames - offset)
        guard copy > 0 else { return }
        let mono = buffer.channelCount == 1
        for i in 0..<copy {
            let dst = offset + i
            let g: Float
            if let f = gainAtFileTime {
                g = f(Double(i) / sr)
            } else {
                g = gain
            }
            if mono {
                let s = buffer.samples[0][i] * g
                left[dst] += s
                right[dst] += s
            } else {
                left[dst] += buffer.samples[0][i] * g
                right[dst] += buffer.samples[1][i] * g
            }
        }
    }

    /// Linear ramp from 1.0 down to `duckAmp` centered at `duckStart`. Outside
    /// the ramp window the gain is held at the end value. With `fadeSec == 0`
    /// the transition is a clean step.
    fileprivate static func rampDown(
        at t: Double,
        duckStart: Double,
        fadeSec: Double,
        duckAmp: Double
    ) -> Float {
        if fadeSec <= 0 {
            return Float(t < duckStart ? 1.0 : duckAmp)
        }
        let rampStart = duckStart - fadeSec / 2
        let rampEnd = duckStart + fadeSec / 2
        if t < rampStart { return 1.0 }
        if t > rampEnd { return Float(duckAmp) }
        let progress = (t - rampStart) / fadeSec
        return Float(1.0 + (duckAmp - 1.0) * progress)
    }

    /// Linear ramp from `duckAmp` up to 1.0 centered at `duckEnd`.
    fileprivate static func rampUp(
        at t: Double,
        duckEnd: Double,
        fadeSec: Double,
        duckAmp: Double
    ) -> Float {
        if fadeSec <= 0 {
            return Float(t < duckEnd ? duckAmp : 1.0)
        }
        let rampStart = duckEnd - fadeSec / 2
        let rampEnd = duckEnd + fadeSec / 2
        if t < rampStart { return Float(duckAmp) }
        if t > rampEnd { return 1.0 }
        let progress = (t - rampStart) / fadeSec
        return Float(duckAmp + (1.0 - duckAmp) * progress)
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
