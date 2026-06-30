import Foundation

/// Renders a `videoEdit` arrangement onto the original video, used once at
/// export. The arrangement maps original-source ranges onto the output
/// timeline; timeline gaps keep the picture rolling (only the audio is silenced
/// there), so the whole thing flattens to an ordered list of source ranges to
/// stitch together.
///
/// The render normalizes the (often VFR) source to one CFR grid, then selects
/// each range by **frame index** and concatenates the pieces. Two things keep
/// the picture frame-accurate against the (sample-accurate) edited audio:
///   1. Cutting on a CFR-normalized stream removes the VFR rate mismatch — the
///      old code trimmed VFR frames and forced CFR only on output, so segments
///      were systematically time-compressed.
///   2. Each segment's output frame count is pinned to the audio timeline via
///      error feedback (`frameSegments`), so the cut points never drift more
///      than half a frame and the error does **not** accumulate across cuts.
/// A copy-based "smart cut" drifts even worse — each segment's container
/// duration overshoots by up to a frame and the gaps pile up.
///
/// The result is **video-only** (no audio) — the per-speaker mp4 muxes the
/// track's own edited WAV back in.
public enum VideoEdit {
    public static func renderArrangement(
        arrangement: Arrangement,
        from videoURL: URL,
        to outURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outURL.path) { try fm.removeItem(at: outURL) }

        let ranges = flattenedRanges(arrangement)
        guard !ranges.isEmpty else {
            throw MaycastError.invalidOperation("Cannot render an empty arrangement to video.")
        }
        let props = try probe(videoURL)
        let fps = fpsValue(props.fps)

        // Normalize the (possibly VFR) input to one CFR grid up front, fan it out
        // with `split`, then select each range by **frame index** so output frame
        // counts are exact. `frameSegments` pins each segment's length to the
        // audio timeline (error feedback), so cut points stay sample-aligned and
        // the per-cut quantization error never accumulates.
        let segments = frameSegments(ranges, fps: fps)
        guard !segments.isEmpty else {
            throw MaycastError.invalidOperation("Cannot render an empty arrangement to video.")
        }
        var filters: [String] = ["[0:v]fps=\(props.fps)[cfr]"]
        let splitLabels = (0..<segments.count).map { "t\($0)" }
        filters.append("[cfr]split=\(segments.count)" + splitLabels.map { "[\($0)]" }.joined())
        var labels: [String] = []
        for (i, seg) in segments.enumerated() {
            let label = "s\(i)"
            let endFrame = seg.startFrame + seg.frameCount
            filters.append("[t\(i)]trim=start_frame=\(seg.startFrame):end_frame=\(endFrame),setpts=PTS-STARTPTS[\(label)]")
            labels.append("[\(label)]")
        }
        let concat = labels.joined() + "concat=n=\(labels.count):v=1:a=0[outv]"
        let filterComplex = (filters + [concat]).joined(separator: ";")

        do {
            try FFmpeg.runWithProgress([
                "-i", videoURL.path,
                "-filter_complex", filterComplex,
                "-map", "[outv]", "-an",
                "-r", props.fps, "-fps_mode", "cfr",
                "-c:v", "h264_videotoolbox", "-b:v", "\(targetBitrate(props))",
                "-pix_fmt", "yuv420p",
                "-video_track_timescale", "90000",
                outURL.path,
            ], expectedDurationSec: arrangement.totalDuration, onProgress: onProgress)
        } catch let error as MaycastError {
            throw MaycastError.audioWriteFailed(outURL, underlying: error)
        }

        // Sanity: a correct render matches the edited timeline to within a couple
        // frames (it used to be allowed to drift up to 0.5s — that tolerance is
        // exactly the lip-sync bug this render now prevents).
        let expected = arrangement.totalDuration
        let tolerance = max(0.1, 2.5 / fps)
        if expected > 0, let actual = try? durationOf(outURL), abs(actual - expected) > tolerance {
            try? fm.removeItem(at: outURL)
            throw MaycastError.invalidOperation(
                "Video render mismatch: got \(String(format: "%.2f", actual))s, expected \(String(format: "%.2f", expected))s."
            )
        }
    }

    // MARK: - Flatten

    /// Ordered source ranges the output is stitched from (clips + the
    /// "keep rolling" fill for timeline gaps). The ranges tile the output
    /// timeline `[0, totalDuration)` exactly: overlapping clips are clamped so
    /// the picture never duplicates content (which would make the render longer
    /// than the edited timeline).
    static func flattenedRanges(_ arrangement: Arrangement) -> [(start: Double, end: Double)] {
        let eps = 0.0005
        let clips = arrangement.clips.sorted { $0.timelineStart < $1.timelineStart }
        var ranges: [(Double, Double)] = []
        var cursorTimeline = 0.0
        var sourceCursor = 0.0
        for clip in clips {
            if clip.timelineEnd <= cursorTimeline + eps { continue }
            if clip.timelineStart > cursorTimeline + eps {
                let gap = clip.timelineStart - cursorTimeline
                ranges.append((sourceCursor, sourceCursor + gap))
                cursorTimeline = clip.timelineStart
            }
            let skip = max(0, cursorTimeline - clip.timelineStart)
            let srcStart = clip.sourceStart + skip
            if clip.sourceEnd - srcStart > eps {
                ranges.append((srcStart, clip.sourceEnd))
            }
            cursorTimeline = clip.timelineEnd
            sourceCursor = clip.sourceEnd
        }
        return ranges
    }

    // MARK: - Frame placement

    /// One output piece: `frameCount` consecutive source frames starting at
    /// `startFrame` (indices into the CFR-normalized stream).
    struct FrameSegment: Equatable {
        var startFrame: Int
        var frameCount: Int
    }

    /// Turn timeline-tiling source ranges into frame-exact output segments.
    ///
    /// `startFrame` snaps each segment to the source frame nearest its cut, so
    /// the picture inside the clip matches the audio it's muxed against. The
    /// `frameCount` is chosen by **error feedback**: the running output-frame
    /// total is kept equal to `round(cumulativeTimeline * fps)` at every cut, so
    /// the boundary never drifts more than half a frame and — crucially — the
    /// rounding error does not accumulate across many cuts (the old lip-sync
    /// drift). Sub-frame slivers (count ≤ 0) are dropped.
    static func frameSegments(_ ranges: [(start: Double, end: Double)], fps: Double) -> [FrameSegment] {
        guard fps > 0 else { return [] }
        var segments: [FrameSegment] = []
        var timelineCursor = 0.0
        var emittedFrames = 0
        for range in ranges {
            let duration = max(0, range.end - range.start)
            timelineCursor += duration
            let target = Int((timelineCursor * fps).rounded())
            let count = target - emittedFrames
            guard count > 0 else { continue }
            let startFrame = Int((range.start * fps).rounded())
            segments.append(FrameSegment(startFrame: max(0, startFrame), frameCount: count))
            emittedFrames = target
        }
        return segments
    }

    private static func targetBitrate(_ props: VideoProps) -> Int {
        max(2_000_000, Int(Double(props.width * props.height) * fpsValue(props.fps) * 0.1))
    }

    // MARK: - Probe

    struct VideoProps { var width: Int; var height: Int; var fps: String }

    /// Reads width / height and a sane output frame rate. Real recordings are
    /// often variable-frame-rate with a nonsense container `r_frame_rate`
    /// (rai-m.mp4 reports 57600), so we prefer the **average** frame rate and
    /// only fall back to `r_frame_rate` (then 30) when it isn't usable.
    private static func probe(_ url: URL) throws -> VideoProps {
        let text = try ffprobeCapture([
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate",
            "-of", "csv=s=,:p=0", url.path,
        ])
        // Trim each field: the csv carries a trailing newline on the last value,
        // which would otherwise leak into `props.fps` and break both `fpsValue`
        // (→ silent 30fps fallback) and the filtergraph string.
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 4, let w = Int(parts[0]), let h = Int(parts[1]) else {
            throw MaycastError.invalidOperation("Could not read video stream properties from \(url.lastPathComponent).")
        }
        let avg = parts[2]   // r_frame_rate
        let avgReal = parts[3]
        let fps = saneFPS(avgReal) ?? saneFPS(avg) ?? "30"
        return VideoProps(width: w, height: h, fps: fps)
    }

    /// Return the rate string if it parses to a plausible fps (1–240), else nil.
    private static func saneFPS(_ s: String) -> String? {
        let v = fpsValue(s)
        return (v >= 1 && v <= 240) ? s : nil
    }

    private static func durationOf(_ url: URL) throws -> Double {
        let text = try ffprobeCapture([
            "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(text) else {
            throw MaycastError.invalidOperation("Could not read duration of \(url.lastPathComponent).")
        }
        return d
    }

    private static func ffprobeCapture(_ arguments: [String]) throws -> String {
        let ffprobe = try FFmpeg.locate("ffprobe")
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func fpsValue(_ s: String) -> Double {
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 { return n / d }
        return Double(s) ?? 30
    }
}
