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
