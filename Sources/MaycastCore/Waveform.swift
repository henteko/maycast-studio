import Foundation
import AVFoundation

/// Min/max peak pairs computed from an `AudioBuffer` at a target resolution.
///
/// The peaks are mono-mixed across channels (for waveform display purposes the
/// per-channel difference is rarely interesting).
public struct WaveformPeaks: Sendable, Equatable {
    public let sampleRate: Double
    public let samplesPerPeak: Int
    public let mins: [Float]
    public let maxs: [Float]

    public var peakCount: Int { mins.count }
    public var secondsPerPeak: Double { Double(samplesPerPeak) / sampleRate }
    public var totalDuration: Double { Double(peakCount) * secondsPerPeak }

    public init(sampleRate: Double, samplesPerPeak: Int, mins: [Float], maxs: [Float]) {
        precondition(mins.count == maxs.count)
        self.sampleRate = sampleRate
        self.samplesPerPeak = samplesPerPeak
        self.mins = mins
        self.maxs = maxs
    }
}

public enum WaveformGenerator {
    /// Stream-read an audio file in fixed-size chunks and compute peaks without
    /// loading the full file into memory.
    ///
    /// Memory cost is O(chunkFrameCount) regardless of file length, making this
    /// suitable for hour-long podcast episodes.
    public static func generateStreaming(
        from url: URL,
        peaksPerSecond: Double = 200,
        chunkFrameCount: AVAudioFrameCount = 65536
    ) throws -> WaveformPeaks {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MaycastError.audioReadFailed(url, underlying: error)
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = Int(file.length)
        let samplesPerPeak = max(1, Int(sampleRate / peaksPerSecond))
        let peakCount = totalFrames / samplesPerPeak

        // Always read into a planar Float32 buffer (matches AudioBuffer layout).
        guard let planarFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: format.channelCount,
            interleaved: false
        ) else {
            throw MaycastError.audioReadFailed(url, underlying: NSError(
                domain: "MaycastCore.Waveform",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to construct planar format"]
            ))
        }
        // Align chunkFrameCount to samplesPerPeak so we don't straddle peaks across chunks.
        let alignedChunk = max(AVAudioFrameCount(samplesPerPeak),
                               (chunkFrameCount / AVAudioFrameCount(samplesPerPeak)) * AVAudioFrameCount(samplesPerPeak))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: planarFormat, frameCapacity: alignedChunk) else {
            throw MaycastError.audioReadFailed(url, underlying: NSError(
                domain: "MaycastCore.Waveform",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate read buffer"]
            ))
        }

        // Set up converter if file format != planar Float32.
        let converter: AVAudioConverter?
        let intermediate: AVAudioPCMBuffer?
        if format != planarFormat {
            guard let conv = AVAudioConverter(from: format, to: planarFormat),
                  let interBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: alignedChunk) else {
                throw MaycastError.audioReadFailed(url, underlying: NSError(
                    domain: "MaycastCore.Waveform",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to set up converter"]
                ))
            }
            converter = conv
            intermediate = interBuf
        } else {
            converter = nil
            intermediate = nil
        }

        var mins = [Float](repeating: 0, count: peakCount)
        var maxs = [Float](repeating: 0, count: peakCount)
        let channelCount = Int(planarFormat.channelCount)
        var globalPeakIndex = 0

        while file.framePosition < AVAudioFramePosition(totalFrames) {
            buffer.frameLength = 0
            if let converter, let intermediate {
                do {
                    try file.read(into: intermediate, frameCount: alignedChunk)
                } catch {
                    throw MaycastError.audioReadFailed(url, underlying: error)
                }
                if intermediate.frameLength == 0 { break }
                var convError: NSError?
                converter.convert(to: buffer, error: &convError) { _, status in
                    status.pointee = .haveData
                    return intermediate
                }
                if let convError {
                    throw MaycastError.audioReadFailed(url, underlying: convError)
                }
            } else {
                do {
                    try file.read(into: buffer, frameCount: alignedChunk)
                } catch {
                    throw MaycastError.audioReadFailed(url, underlying: error)
                }
            }
            let framesRead = Int(buffer.frameLength)
            guard framesRead > 0, let channelData = buffer.floatChannelData else { break }

            let chunkPeaks = framesRead / samplesPerPeak
            for p in 0..<chunkPeaks where globalPeakIndex < peakCount {
                let start = p * samplesPerPeak
                let end = start + samplesPerPeak
                var minV: Float = 0
                var maxV: Float = 0
                for ch in 0..<channelCount {
                    let ptr = channelData[ch]
                    for i in start..<end {
                        let s = ptr[i]
                        if s < minV { minV = s }
                        if s > maxV { maxV = s }
                    }
                }
                mins[globalPeakIndex] = minV
                maxs[globalPeakIndex] = maxV
                globalPeakIndex += 1
            }
            if framesRead < Int(alignedChunk) { break }
        }

        return WaveformPeaks(
            sampleRate: sampleRate,
            samplesPerPeak: samplesPerPeak,
            mins: mins,
            maxs: maxs
        )
    }

    /// Compute peaks for an audio buffer at the requested resolution (peaks per second).
    /// A common value is 100–200 px/sec for editor-scale waveforms; higher rates
    /// produce more accurate detail at higher memory cost.
    public static func generate(_ buffer: AudioBuffer, peaksPerSecond: Double = 200) -> WaveformPeaks {
        let samplesPerPeak = max(1, Int(buffer.sampleRate / peaksPerSecond))
        let peakCount = buffer.frameCount / samplesPerPeak
        var mins = [Float](repeating: 0, count: peakCount)
        var maxs = [Float](repeating: 0, count: peakCount)
        let channelCount = buffer.channelCount
        for p in 0..<peakCount {
            let start = p * samplesPerPeak
            let end = min(start + samplesPerPeak, buffer.frameCount)
            var minV: Float = 0
            var maxV: Float = 0
            for ch in 0..<channelCount {
                for i in start..<end {
                    let s = buffer.samples[ch][i]
                    if s < minV { minV = s }
                    if s > maxV { maxV = s }
                }
            }
            mins[p] = minV
            maxs[p] = maxV
        }
        return WaveformPeaks(
            sampleRate: buffer.sampleRate,
            samplesPerPeak: samplesPerPeak,
            mins: mins,
            maxs: maxs
        )
    }
}
