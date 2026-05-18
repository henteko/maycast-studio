import Foundation
import AVFoundation
import SwiftUI
import MaycastCore

// MARK: - Waveform cache

/// In-memory cache of computed peak data keyed by file path.
@MainActor
@Observable
final class WaveformCache {
    private var peaksByPath: [String: WaveformPeaks] = [:]

    func peaks(for path: String) -> WaveformPeaks? {
        peaksByPath[path]
    }

    func set(_ peaks: WaveformPeaks, for path: String) {
        peaksByPath[path] = peaks
    }

    @discardableResult
    func computeIfNeeded(at url: URL, peaksPerSecond: Double = 200) throws -> WaveformPeaks {
        if let cached = peaksByPath[url.path] { return cached }
        let buffer = try AudioIO.read(from: url)
        let peaks = WaveformGenerator.generate(buffer, peaksPerSecond: peaksPerSecond)
        peaksByPath[url.path] = peaks
        return peaks
    }
}

// MARK: - Waveform view

/// Renders a slice of `WaveformPeaks` (defined by source-time range) into a Canvas.
///
/// Subsamples to roughly 2 buckets per display pixel and emits a single
/// composed `Path`, keeping per-frame draw cost low even for long clips.
struct WaveformView: View {
    let peaks: WaveformPeaks
    let startTime: Double
    let endTime: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            let secondsPerPeak = peaks.secondsPerPeak
            guard secondsPerPeak > 0, peaks.peakCount > 0, size.width > 0 else { return }
            let startIndex = max(0, Int(startTime / secondsPerPeak))
            let endIndex = min(peaks.peakCount, Int(endTime / secondsPerPeak))
            let available = endIndex - startIndex
            guard available > 0 else { return }

            let bucketCount = max(1, min(available, Int(size.width * 2)))
            let bucketWidth = size.width / CGFloat(bucketCount)
            let centerY = size.height / 2
            let halfHeight = size.height / 2

            // Distribute `available` peaks across `bucketCount` buckets using
            // fractional boundaries. Integer division (`available /
            // bucketCount`) used to silently drop the tail (up to
            // bucketCount-1 peaks), which made the waveform stop short of the
            // right edge — visible as a drift when zoomed out.
            let stride = Double(available) / Double(bucketCount)

            var path = Path()
            for i in 0..<bucketCount {
                let bStart = startIndex + Int((Double(i) * stride).rounded(.down))
                let bEndRaw = startIndex + Int((Double(i + 1) * stride).rounded(.down))
                let bEnd = min(max(bEndRaw, bStart + 1), endIndex)
                guard bEnd > bStart else { continue }
                var minV: Float = 0
                var maxV: Float = 0
                for j in bStart..<bEnd {
                    if peaks.mins[j] < minV { minV = peaks.mins[j] }
                    if peaks.maxs[j] > maxV { maxV = peaks.maxs[j] }
                }
                let topY = centerY - CGFloat(maxV) * halfHeight
                let bottomY = centerY - CGFloat(minV) * halfHeight
                let x = CGFloat(i) * bucketWidth
                path.addRect(CGRect(
                    x: x,
                    y: topY,
                    width: max(1, bucketWidth - 0.5),
                    height: max(1, bottomY - topY)
                ))
            }
            context.fill(path, with: .color(color.opacity(0.85)))
        }
    }
}

// MARK: - Playback engine

/// Multi-track audio playback that respects each track's clip arrangement.
///
/// Each track schedules its clip segments (with silent fills for gaps from
/// deletions/moves) so that during playback the editor's draft arrangement
/// is what the user hears. Call `setArrangements(_:)` to push current drafts
/// into the engine before pressing Play.
@MainActor
@Observable
final class PlaybackEngine {
    var playheadTime: Double = 0
    var isPlaying: Bool = false
    var totalDuration: Double = 0
    var lastError: String?

    /// Playback rate (1.0 = normal). Setting this updates the per-track
    /// `AVAudioUnitTimePitch.rate` immediately so the change takes effect even
    /// during playback. Pitch is preserved across rate changes (TimePitch),
    /// which matches the typical podcast-editor use case of scanning content
    /// at 1.5–2x without sounding chipmunky.
    var playbackRate: Float = 1.0 {
        didSet {
            guard playbackRate != oldValue else { return }
            for entry in entries { entry.timePitch.rate = playbackRate }
        }
    }

    private let engine = AVAudioEngine()
    private struct TrackEntry {
        let trackID: String
        let player: AVAudioPlayerNode
        let timePitch: AVAudioUnitTimePitch
        let file: AVAudioFile
        var arrangement: Arrangement
    }
    private var entries: [TrackEntry] = []
    private var seekOffset: Double = 0
    private var timer: Timer?

    // MARK: - Load / update

    /// Load a fresh set of tracks (each one paired with its arrangement and
    /// source audio URL). Stops any current playback.
    func load(tracks: [(trackID: String, arrangement: Arrangement, sourceURL: URL)]) {
        stop()
        for entry in entries {
            engine.disconnectNodeOutput(entry.player)
            engine.disconnectNodeOutput(entry.timePitch)
            engine.detach(entry.player)
            engine.detach(entry.timePitch)
        }
        entries.removeAll()

        do {
            let mixer = engine.mainMixerNode
            for t in tracks {
                let file = try AVAudioFile(forReading: t.sourceURL)
                let player = AVAudioPlayerNode()
                let timePitch = AVAudioUnitTimePitch()
                timePitch.rate = playbackRate
                engine.attach(player)
                engine.attach(timePitch)
                engine.connect(player, to: timePitch, format: file.processingFormat)
                engine.connect(timePitch, to: mixer, format: file.processingFormat)
                entries.append(TrackEntry(
                    trackID: t.trackID,
                    player: player,
                    timePitch: timePitch,
                    file: file,
                    arrangement: t.arrangement
                ))
            }
            recomputeTotalDuration()
            if !engine.isRunning {
                try engine.start()
            }
            lastError = nil
        } catch {
            lastError = "Failed to load tracks: \(error)"
        }
    }

    /// Update arrangements for already-loaded tracks. Typically called by the
    /// editor immediately before `play()` so playback reflects the latest drafts.
    func setArrangements(_ arrangements: [String: Arrangement]) {
        for i in 0..<entries.count {
            if let arr = arrangements[entries[i].trackID] {
                entries[i].arrangement = arr
            }
        }
        recomputeTotalDuration()
    }

    private func recomputeTotalDuration() {
        totalDuration = entries.map { $0.arrangement.totalDuration }.max() ?? 0
    }

    // MARK: - Transport

    func play() {
        guard !isPlaying, !entries.isEmpty else { return }
        if !engine.isRunning {
            do { try engine.start() } catch {
                lastError = "Failed to start engine: \(error)"
                return
            }
        }
        for entry in entries {
            scheduleFromSeek(entry: entry)
            entry.player.play()
        }
        isPlaying = true
        startTimer()
    }

    func pause() {
        guard isPlaying else { return }
        let now = playheadTime
        for entry in entries { entry.player.pause() }
        for entry in entries { entry.player.stop() }
        seekOffset = now
        isPlaying = false
        stopTimer()
    }

    func stop() {
        for entry in entries { entry.player.stop() }
        isPlaying = false
        playheadTime = 0
        seekOffset = 0
        stopTimer()
    }

    func seek(to time: Double) {
        let wasPlaying = isPlaying
        if isPlaying {
            for entry in entries { entry.player.stop() }
            isPlaying = false
            stopTimer()
        }
        seekOffset = max(0, min(time, totalDuration))
        playheadTime = seekOffset
        if wasPlaying { play() }
    }

    // MARK: - Internals

    /// Schedule playback for a single track from `seekOffset`. Walks the
    /// arrangement's clips in timeline order, fills any gap with a silent
    /// buffer of the gap duration, and queues each clip segment from its
    /// source range.
    private func scheduleFromSeek(entry: TrackEntry) {
        let player = entry.player
        let file = entry.file
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        player.stop()

        let sortedClips = entry.arrangement.clips.sorted { $0.timelineStart < $1.timelineStart }
        var cursor = seekOffset

        for clip in sortedClips {
            if clip.timelineEnd <= seekOffset { continue }
            if clip.timelineStart > cursor {
                let gap = clip.timelineStart - cursor
                scheduleSilence(player: player, format: format, duration: gap)
                cursor = clip.timelineStart
            }
            let skipWithin = max(0, cursor - clip.timelineStart)
            let playDuration = clip.duration - skipWithin
            guard playDuration > 0 else { continue }

            let startFrame = AVAudioFramePosition(((clip.sourceStart + skipWithin) * sampleRate).rounded())
            let requested = AVAudioFrameCount((playDuration * sampleRate).rounded())
            let available = AVAudioFrameCount(max(0, Int(file.length) - Int(startFrame)))
            let count = min(requested, available)
            guard count > 0 else { continue }
            player.scheduleSegment(file, startingFrame: startFrame, frameCount: count,
                                   at: nil, completionHandler: nil)
            cursor = clip.timelineEnd
        }
    }

    private func scheduleSilence(player: AVAudioPlayerNode, format: AVAudioFormat, duration: Double) {
        let frames = AVAudioFrameCount(max(0, duration * format.sampleRate))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        // PCM buffers start zero-initialised → silence.
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying, let first = entries.first else { return }
        if let nodeTime = first.player.lastRenderTime,
           let playerTime = first.player.playerTime(forNodeTime: nodeTime) {
            let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
            let candidate = seekOffset + max(0, elapsed)
            if totalDuration > 0, candidate >= totalDuration {
                stop()
            } else {
                playheadTime = candidate
            }
        }
    }
}
