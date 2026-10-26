import Foundation

/// The provider-independent tail of every polish run: match the files a
/// service returned to speaker IDs, then write one `polish` generation per
/// track into the bundle under a shared batch ID.
public enum PolishIngest {
    static let audioExtensions: Set<String> = ["wav", "flac", "mp3", "m4a", "aiff", "aif"]

    /// Assign returned audio files to speakers by name. Services name their
    /// outputs after what we uploaded (`<id>.wav`), usually with a prefix or
    /// suffix (`<title>_<id>.wav`, `<id>_cleaned.wav`), so boundary-based
    /// matching is used. A lone speaker takes a lone file regardless of name.
    public static func assign(files: [URL], to speakerIDs: [String]) -> [String: URL] {
        let audioFiles = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        var bySpeaker: [String: URL] = [:]
        for file in audioFiles {
            let stem = file.deletingPathExtension().lastPathComponent
            if let id = matchSpeakerID(in: stem, candidates: speakerIDs), bySpeaker[id] == nil {
                bySpeaker[id] = file
            }
        }
        if bySpeaker.isEmpty, speakerIDs.count == 1, audioFiles.count == 1 {
            bySpeaker[speakerIDs[0]] = audioFiles[0]
        }
        return bySpeaker
    }

    /// Pick the speaker ID that appears as a delimited token in `haystack`.
    /// Boundary characters = anything non-alphanumeric, plus the start / end of
    /// the string. The longest match wins so `"audio_xxx_host2"` resolves to
    /// `host2` instead of `host`.
    public static func matchSpeakerID(in haystack: String, candidates: [String]) -> String? {
        let lower = haystack.lowercased()
        let matches = candidates.filter { id in
            let needle = id.lowercased()
            let escaped = NSRegularExpression.escapedPattern(for: needle)
            let pattern = "(^|[^a-z0-9])\(escaped)([^a-z0-9]|$)"
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
            let range = NSRange(lower.startIndex..., in: lower)
            return re.firstMatch(in: lower, range: range) != nil
        }
        return matches.sorted { $0.count > $1.count }.first
    }

    /// Write one polish generation per speaker.
    ///
    /// `videoCut` is asked, for each speaker whose track has video, for the
    /// cut the service applied — a kept-region arrangement over the current
    /// timeline (`nil` ⇒ no length change). It's composed into the cumulative
    /// video edit, so the picture follows the cleaned audio. Every cut is
    /// resolved before anything is written, so a throwing `videoCut` leaves
    /// the bundle untouched.
    /// - Throws: `PolishIngestError.missingTrack` if a speaker has no cleaned
    ///   file (checked up front, so nothing is written on a partial result).
    public static func writeGenerations(
        bundleURL: URL,
        speakers: [PolishSpeaker],
        cleaned: [String: URL],
        videoCut: (_ speaker: PolishSpeaker, _ cleanedFile: URL) throws -> Arrangement? = { _, _ in nil },
        params: JSONValue?,
        returnedFiles: [URL] = []
    ) throws -> [PolishTrackOutput] {
        for sp in speakers where cleaned[sp.id] == nil {
            throw PolishIngestError.missingTrack(
                id: sp.id,
                returnedFiles: returnedFiles.map(\.lastPathComponent)
            )
        }

        var bundle = try EpisodeBundle.open(at: bundleURL)
        // Nothing is encoded for video here — the cut is recorded and
        // rendered onto the original video at export, so Polish stays fast.
        var videoCuts: [String: Arrangement] = [:]
        for sp in speakers where bundle.track(withID: sp.id)?.hasVideo == true {
            videoCuts[sp.id] = try videoCut(sp, cleaned[sp.id]!)
        }

        // Shared batchID so a single undo reverts every speaker's polish at
        // once, matching the "one Apply press = one undo step" mental model.
        let batchID = UUID().uuidString
        var outputs: [PolishTrackOutput] = []
        for sp in speakers {
            let track = try bundle.appendPolishGeneration(
                trackID: sp.id,
                audioWAVSource: cleaned[sp.id]!,
                videoCut: videoCuts[sp.id],
                params: params,
                batchID: batchID
            )
            outputs.append(PolishTrackOutput(trackID: sp.id, generationPath: track.current))
        }
        return outputs
    }
}

public enum PolishIngestError: Error, CustomStringConvertible, Sendable {
    case missingTrack(id: String, returnedFiles: [String])

    public var description: String {
        switch self {
        case .missingTrack(let id, let files):
            return "Could not find the cleaned track for '\(id)'. Files returned: \(files)"
        }
    }
}
