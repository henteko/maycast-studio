import Foundation

/// Renders a `videoEdit` arrangement onto the original video, used once at
/// export. The arrangement maps original-source ranges onto the output
/// timeline; timeline gaps keep the picture rolling (only the audio is silenced
/// there), so the whole thing flattens to an ordered list of source ranges to
/// stitch together.
///
/// **Smart cut**: rather than re-encoding everything, each source range is
/// stream-copied over its keyframe-aligned interior and only the partial GOPs
/// at the cut boundaries are re-encoded — near-copy speed while staying
/// frame-accurate. If a render can't be done this way (unsupported codec, no
/// usable keyframes, or the stitched result doesn't match the edited timeline)
/// it throws — there is no full-re-encode fallback.
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

        try smartRender(ranges: ranges, from: videoURL, to: outURL, props: props, onProgress: onProgress)

        // The stitched result must match the edited timeline; if not, the cut
        // went wrong — surface it as an error rather than ship a bad render.
        // Allow a small slack that grows with the number of cuts: each boundary
        // can only land on a frame, so frame-rounding accumulates ~1 frame per
        // cut (and the final mux trims any tail to the audio length anyway).
        let expected = arrangement.totalDuration
        let tolerance = max(2.0, Double(ranges.count) * 0.2)
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
            // Wholly covered by an earlier (overlapping) clip → nothing to add.
            if clip.timelineEnd <= cursorTimeline + eps { continue }
            // Timeline gap before the clip → keep the picture rolling.
            if clip.timelineStart > cursorTimeline + eps {
                let gap = clip.timelineStart - cursorTimeline
                ranges.append((sourceCursor, sourceCursor + gap))
                cursorTimeline = clip.timelineStart
            }
            // Emit only the portion of the clip past the cursor (clamp overlap).
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

    // MARK: - Smart cut

    private static let boundaryEpsilon = 0.02
    /// Only bother stream-copying when the keyframe-aligned interior is at least
    /// this long; shorter ranges are simply re-encoded whole.
    private static let minCopyDuration = 1.0

    private static func smartRender(
        ranges: [(start: Double, end: Double)],
        from videoURL: URL,
        to outURL: URL,
        props: VideoProps,
        onProgress: (@Sendable (Double) -> Void)?
    ) throws {
        let codec = try probeCodec(videoURL)
        guard let encoder = matchingEncoder(for: codec) else {
            throw MaycastError.invalidOperation("Video render unsupported for codec '\(codec)'.")
        }
        // Keyframes may be sparse (or just the first frame) — ranges without a
        // usable keyframe-aligned interior are simply re-encoded whole, which is
        // smart-cut's normal boundary handling, not a failure.
        let keyframes = try probeKeyframes(videoURL)

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("maycast-smartcut-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let bitrate = targetBitrate(props)
        var segmentFiles: [URL] = []
        for (i, range) in ranges.enumerated() {
            segmentFiles += try cutRange(
                range.start, range.end,
                from: videoURL, keyframes: keyframes,
                encoder: encoder, bitrate: bitrate, scratch: scratch
            )
            onProgress?(Double(i + 1) / Double(ranges.count) * 0.95)
        }
        guard !segmentFiles.isEmpty else {
            throw MaycastError.invalidOperation("smart-cut produced no segments")
        }

        // Concatenate the (copied + re-encoded) segments without another encode.
        let listFile = scratch.appendingPathComponent("concat.txt")
        let listText = segmentFiles.map { "file '\($0.path)'" }.joined(separator: "\n") + "\n"
        try listText.write(to: listFile, atomically: true, encoding: .utf8)
        try FFmpeg.run([
            "-f", "concat", "-safe", "0", "-i", listFile.path,
            "-an", "-c:v", "copy",
            "-movflags", "+faststart",
            outURL.path,
        ])
        onProgress?(1.0)
    }

    /// Split one source range into [head re-encode?] + [keyframe-aligned copy] +
    /// [tail re-encode?]. If no usable copy interior exists, re-encode it whole.
    private static func cutRange(
        _ start: Double, _ end: Double,
        from videoURL: URL, keyframes: [Double],
        encoder: String, bitrate: Int, scratch: URL
    ) throws -> [URL] {
        let eps = boundaryEpsilon
        let copyStart = keyframes.first { $0 >= start - eps }
        let copyEnd = keyframes.last { $0 <= end + eps }
        guard let ks = copyStart, let ke = copyEnd,
              ks >= start - eps, ke <= end + eps, ke - ks >= minCopyDuration
        else {
            return [try reencodeSegment(start, end, from: videoURL, encoder: encoder, bitrate: bitrate, scratch: scratch)]
        }
        var parts: [URL] = []
        if ks - start > eps {
            parts.append(try reencodeSegment(start, ks, from: videoURL, encoder: encoder, bitrate: bitrate, scratch: scratch))
        }
        parts.append(try copySegment(ks, ke, from: videoURL, scratch: scratch))
        if end - ke > eps {
            parts.append(try reencodeSegment(ke, end, from: videoURL, encoder: encoder, bitrate: bitrate, scratch: scratch))
        }
        return parts
    }

    /// All segments are written with the same MP4 timescale so the concat
    /// demuxer can stitch the copied (source timebase) and re-encoded (encoder
    /// timebase) pieces without mis-accumulating timestamps — a mismatch here
    /// inflated the stitched duration several-fold on variable-frame-rate
    /// sources.
    private static let segmentTimescale = "90000"

    private static func copySegment(_ start: Double, _ end: Double, from videoURL: URL, scratch: URL) throws -> URL {
        let out = scratch.appendingPathComponent("c-\(UUID().uuidString).mp4")
        try FFmpeg.run([
            "-ss", fmt(start), "-i", videoURL.path, "-t", fmt(end - start),
            "-an", "-c:v", "copy",
            "-avoid_negative_ts", "make_zero",
            "-video_track_timescale", segmentTimescale,
            out.path,
        ])
        return out
    }

    private static func reencodeSegment(_ start: Double, _ end: Double, from videoURL: URL, encoder: String, bitrate: Int, scratch: URL) throws -> URL {
        let out = scratch.appendingPathComponent("r-\(UUID().uuidString).mp4")
        try FFmpeg.run([
            "-ss", fmt(start), "-i", videoURL.path, "-t", fmt(end - start),
            "-an",
            "-vf", "setsar=1",
            "-c:v", encoder, "-b:v", "\(bitrate)", "-pix_fmt", "yuv420p",
            "-video_track_timescale", segmentTimescale,
            out.path,
        ])
        return out
    }

    /// Hardware encoder matching the source codec, so re-encoded boundary
    /// segments concat-copy cleanly with the copied interior.
    private static func matchingEncoder(for codec: String) -> String? {
        switch codec.lowercased() {
        case "h264", "avc1": return "h264_videotoolbox"
        case "hevc", "h265", "hvc1": return "hevc_videotoolbox"
        default: return nil
        }
    }

    private static func targetBitrate(_ props: VideoProps) -> Int {
        max(2_000_000, Int(Double(props.width * props.height) * fpsValue(props.fps) * 0.1))
    }

    // MARK: - Probe

    struct VideoProps { var width: Int; var height: Int; var fps: String }

    private static func probe(_ url: URL) throws -> VideoProps {
        let text = try ffprobeCapture([
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate",
            "-of", "csv=s=,:p=0", url.path,
        ])
        let parts = text.split(separator: ",").map(String.init)
        guard parts.count >= 3, let w = Int(parts[0]), let h = Int(parts[1]),
              !parts[2].isEmpty, parts[2] != "0/0"
        else {
            throw MaycastError.invalidOperation("Could not read video stream properties from \(url.lastPathComponent).")
        }
        return VideoProps(width: w, height: h, fps: parts[2])
    }

    private static func probeCodec(_ url: URL) throws -> String {
        try ffprobeCapture([
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keyframe presentation times (seconds), ascending. Reads packet flags
    /// (no decode), so it's fast even on long videos.
    private static func probeKeyframes(_ url: URL) throws -> [Double] {
        let text = try ffprobeCapture([
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", url.path,
        ])
        var times: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 2, cols[1].contains("K"), let t = Double(cols[0]) else { continue }
            times.append(t)
        }
        return times.sorted()
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

    private static func fmt(_ v: Double) -> String { String(format: "%.6f", max(0, v)) }
}
