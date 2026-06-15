import Foundation

/// Cuts a video to match a slice `Arrangement`, so a track's video stays on the
/// same timeline as its audio. The arrangement's clips (`sourceStart..sourceEnd`
/// placed at `timelineStart`) are reproduced on the video exactly as
/// `AudioIO.render` reproduces them on the audio: each clip is trimmed from the
/// source and laid out in timeline order, and any gap between clips becomes a
/// black segment (mirroring the silence the audio render zero-fills).
///
/// The result is a **video-only** file (no audio) — the per-speaker mp4 export
/// muxes the track's own edited WAV back in, so the video generation only needs
/// a correct picture timeline.
///
/// Re-encodes via `ffmpeg` + libx264 (a trim/concat filtergraph can't stream-
/// copy), so quality degrades slightly across repeated slices — acceptable for
/// the parallel-video-chain model; keyframe-aligned copy is a later
/// optimization.
public enum VideoEdit {
    public static func renderArrangement(
        arrangement: Arrangement,
        from videoURL: URL,
        to outURL: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outURL.path) { try fm.removeItem(at: outURL) }

        let props = try probe(videoURL)
        let clips = arrangement.clips.sorted { $0.timelineStart < $1.timelineStart }
        guard !clips.isEmpty else {
            throw MaycastError.invalidOperation("Cannot render an empty arrangement to video.")
        }

        var filters: [String] = []
        var segments: [String] = []
        var blackIndex = 0
        var cursor = 0.0
        for (i, clip) in clips.enumerated() {
            let gap = clip.timelineStart - cursor
            if gap > 0.0005 {
                let label = "b\(blackIndex)"; blackIndex += 1
                filters.append(
                    "color=c=black:s=\(props.width)x\(props.height):r=\(props.fps):d=\(fmt(gap)),format=yuv420p,setsar=1[\(label)]"
                )
                segments.append("[\(label)]")
            }
            let label = "v\(i)"
            filters.append(
                "[0:v]trim=start=\(fmt(clip.sourceStart)):end=\(fmt(clip.sourceEnd)),setpts=PTS-STARTPTS,fps=\(props.fps),format=yuv420p,setsar=1[\(label)]"
            )
            segments.append("[\(label)]")
            cursor = max(cursor, clip.timelineEnd)
        }

        let concat = segments.joined() + "concat=n=\(segments.count):v=1:a=0[outv]"
        let filterComplex = (filters + [concat]).joined(separator: ";")

        do {
            try FFmpeg.run([
                "-i", videoURL.path,
                "-filter_complex", filterComplex,
                "-map", "[outv]",
                "-an",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                outURL.path,
            ])
        } catch let error as MaycastError {
            throw MaycastError.audioWriteFailed(outURL, underlying: error)
        }
    }

    // MARK: - Probe

    struct VideoProps { var width: Int; var height: Int; var fps: String }

    /// Read width / height / frame rate of the first video stream via ffprobe.
    private static func probe(_ url: URL) throws -> VideoProps {
        let ffprobe = try FFmpeg.locate("ffprobe")
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate",
            "-of", "csv=s=,:p=0",
            url.path,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ",").map(String.init)
        guard parts.count >= 3,
              let w = Int(parts[0]), let h = Int(parts[1]),
              !parts[2].isEmpty, parts[2] != "0/0"
        else {
            throw MaycastError.invalidOperation("Could not read video stream properties from \(url.lastPathComponent).")
        }
        return VideoProps(width: w, height: h, fps: parts[2])
    }

    /// Format a duration with fixed precision so ffmpeg never sees locale commas
    /// or scientific notation.
    private static func fmt(_ v: Double) -> String {
        String(format: "%.6f", max(0, v))
    }
}
