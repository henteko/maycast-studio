import Foundation

/// Builds an ffmetadata document (see ffmpeg's "Metadata" muxer) describing a
/// list of chapters, shared by the MP3 export (`AssetExportPipeline`) and the
/// per-speaker MP4 export (`EpisodeExporter`). Each chapter runs from its own
/// start to the next chapter's start (the last one to `totalDuration`), in
/// millisecond timebase.
public enum FFMetadata {
    public static func chaptersDocument(chapters: [ExportChapter], totalDuration: Double) -> String {
        let sorted = chapters.sorted { $0.startSec < $1.startSec }
        let totalMs = Int((totalDuration * 1000).rounded())
        var lines = [";FFMETADATA1"]
        for (i, chapter) in sorted.enumerated() {
            let startMs = max(0, Int((chapter.startSec * 1000).rounded()))
            let nextMs = (i + 1 < sorted.count)
                ? Int((sorted[i + 1].startSec * 1000).rounded())
                : totalMs
            // ffmpeg rejects zero / negative-length chapters; clamp to ≥ 1 ms.
            let endMs = max(nextMs, startMs + 1)
            lines.append("")
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(startMs)")
            lines.append("END=\(endMs)")
            lines.append("title=\(escape(chapter.title))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Escape the characters ffmetadata treats specially (`=`, `;`, `#`, `\`,
    /// and newline) by prefixing them with a backslash.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            if ch == "=" || ch == ";" || ch == "#" || ch == "\\" || ch == "\n" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}
