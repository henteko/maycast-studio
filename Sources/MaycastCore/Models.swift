import Foundation

// MARK: - Episode

public struct Episode: Codable, Sendable, Equatable {
    public var id: String
    public var uuid: UUID
    public var show: String?
    public var tracks: [Track]
    public var mix: MixConfig
    /// Ordered append-only log of operations that changed any track's
    /// `current`. The newest entries are at the end. Used by `EpisodeBundle`
    /// to implement undo / redo.
    public var operations: [OperationLogEntry]
    /// Entries that were popped from `operations` by `undo()` and are
    /// available to `redo()`. Cleared on every fresh operation.
    public var undone: [OperationLogEntry]
    /// Episode-level chapter markers. Generated from the transcript (local
    /// LLM) and hand-editable, then embedded into the final mix. Stored in the
    /// **voice timeline** (same as the transcript); the intro-lead shift onto
    /// the final mix timeline happens at export time. See docs/chapters.md.
    public var chapters: [Chapter]
    /// Editing cues: utterances in the transcript where a host asks for an edit
    /// ("ここカットで", "今のなしで", …). Detected by Gemini from the transcript
    /// and surfaced as highlights in the slice editor so the user can find cut
    /// points quickly. Stored in the **voice timeline** (same as the transcript).
    public var editCues: [EditCue]

    public init(
        id: String,
        uuid: UUID = UUID(),
        show: String? = nil,
        tracks: [Track] = [],
        mix: MixConfig = MixConfig(),
        operations: [OperationLogEntry] = [],
        undone: [OperationLogEntry] = [],
        chapters: [Chapter] = [],
        editCues: [EditCue] = []
    ) {
        self.id = id
        self.uuid = uuid
        self.show = show
        self.tracks = tracks
        self.mix = mix
        self.operations = operations
        self.undone = undone
        self.chapters = chapters
        self.editCues = editCues
    }

    enum CodingKeys: String, CodingKey {
        case id, uuid, show, tracks, mix, operations, undone, chapters, editCues
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.uuid = try c.decode(UUID.self, forKey: .uuid)
        self.show = try c.decodeIfPresent(String.self, forKey: .show)
        self.tracks = try c.decode([Track].self, forKey: .tracks)
        self.mix = try c.decode(MixConfig.self, forKey: .mix)
        // Backward-compatible: older episode.json files won't have these keys.
        self.operations = (try? c.decodeIfPresent([OperationLogEntry].self, forKey: .operations)) ?? []
        self.undone = (try? c.decodeIfPresent([OperationLogEntry].self, forKey: .undone)) ?? []
        self.chapters = (try? c.decodeIfPresent([Chapter].self, forKey: .chapters)) ?? []
        self.editCues = (try? c.decodeIfPresent([EditCue].self, forKey: .editCues)) ?? []
    }
}

/// One editing cue: a stretch of transcript where a host verbally asks for an
/// edit ("ここカットで", "今の言い直す", …). `start`/`end` are in the **voice
/// timeline** (same as the transcript). Detected from the transcript by Gemini
/// and shown as a highlight in the slice editor; not embedded into any export.
public struct EditCue: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    /// The flagged utterance, as transcribed (may contain ASR errors).
    public var text: String
    public var kind: EditCueKind

    public init(
        id: String = UUID().uuidString,
        start: Double,
        end: Double,
        text: String,
        kind: EditCueKind = .other
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.kind = kind
    }
}

/// Category of an editing cue, used for labelling / colouring the highlight.
/// Decodes unknown strings to `.other` so new categories never break loading.
public enum EditCueKind: String, Codable, Sendable, CaseIterable {
    case cut       // remove this part — "カット", "切って", "ここ要らない"
    case retake    // redo / restate — "今のなし", "言い直す", "もう一回"
    case skip      // skip / handle later — "飛ばして", "後で"
    case other     // any other edit instruction

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EditCueKind(rawValue: raw) ?? .other
    }
}

/// One chapter marker. `start` is in the **voice timeline** (the same timeline
/// as the transcript); the offset onto the final mix timeline is applied at
/// export time. See docs/chapters.md §3.
public struct Chapter: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Double
    public var title: String
    public var source: ChapterSource

    public init(
        id: String = UUID().uuidString,
        start: Double,
        title: String,
        source: ChapterSource = .manual
    ) {
        self.id = id
        self.start = start
        self.title = title
        self.source = source
    }
}

/// Provenance of a chapter.
public enum ChapterSource: String, Codable, Sendable {
    case generated   // produced by the LLM, untouched
    case edited      // LLM output the user has since tweaked
    case manual      // added by hand
}

/// One entry in the per-episode operation log. Multi-track operations from a
/// single user action share the same `batchID` so `undo()` can revert them
/// together (e.g. Polish that updated host + guest at once).
public struct OperationLogEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var batchID: String
    public var kind: String
    public var trackID: String
    public var from: String
    public var to: String
    public var timestamp: Date

    public init(
        id: String = UUID().uuidString,
        batchID: String,
        kind: String,
        trackID: String,
        from: String,
        to: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.batchID = batchID
        self.kind = kind
        self.trackID = trackID
        self.from = from
        self.to = to
        self.timestamp = timestamp
    }
}

public struct Track: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: String
    public var current: String
    public var history: [String]

    /// Original video container (`sources/<id>.<ext>`) when the track was
    /// imported from a video. `nil` for audio-only tracks. Immutable, like
    /// `source`. The video is **never re-encoded during editing** — instead the
    /// cut is tracked in `videoEdit` and applied to this original once, at
    /// export (deferred rendering).
    public var videoSource: String?
    /// Cumulative edit mapping the **original video → the current timeline**
    /// (the same net cuts baked into the `current` audio). Updated by composing
    /// each slice / polish edit; `nil` for audio-only tracks. Applied to
    /// `videoSource` at export to produce the cut mp4.
    public var videoEdit: Arrangement?
    /// Parallel history of `videoEdit` states (mirrors `history`), so undo /
    /// redo / revert move the video edit alongside the audio.
    public var videoEditHistory: [Arrangement]?

    public init(
        id: String,
        source: String,
        current: String,
        history: [String],
        videoSource: String? = nil,
        videoEdit: Arrangement? = nil,
        videoEditHistory: [Arrangement]? = nil
    ) {
        self.id = id
        self.source = source
        self.current = current
        self.history = history
        self.videoSource = videoSource
        self.videoEdit = videoEdit
        self.videoEditHistory = videoEditHistory
    }

    /// Whether this track carries video (and so contributes a per-speaker mp4).
    public var hasVideo: Bool { videoSource != nil && videoEdit != nil }
}

public struct MixConfig: Codable, Sendable, Equatable {
    public var intro: String?
    public var outro: String?
    public var bgm: BGMConfig?
    /// Seconds of overlap between the intro and the start of the voice mix.
    /// During this region the intro ducks to `duckingGainDB` so the host's
    /// voice cuts through. Default 2.0.
    public var introOffsetSec: Double
    /// Seconds of overlap between the end of the voice mix and the outro.
    /// During this region the outro is at `duckingGainDB` and ramps up to
    /// full afterwards. Default 5.0.
    public var outroOffsetSec: Double
    /// Level (dB) that the intro / outro ducks down to during the overlap.
    /// Must be ≤ 0. Default -12 dB.
    public var duckingGainDB: Double
    /// Length of the duck-down / duck-up ramp, in seconds. Default 0.5.
    public var duckingFadeSec: Double

    public init(
        intro: String? = nil,
        outro: String? = nil,
        bgm: BGMConfig? = nil,
        introOffsetSec: Double = 2.0,
        outroOffsetSec: Double = 5.0,
        duckingGainDB: Double = -12,
        duckingFadeSec: Double = 0.5
    ) {
        self.intro = intro
        self.outro = outro
        self.bgm = bgm
        self.introOffsetSec = introOffsetSec
        self.outroOffsetSec = outroOffsetSec
        self.duckingGainDB = duckingGainDB
        self.duckingFadeSec = duckingFadeSec
    }

    enum CodingKeys: String, CodingKey {
        case intro, outro, bgm
        case introOffsetSec, outroOffsetSec, duckingGainDB, duckingFadeSec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.intro = try c.decodeIfPresent(String.self, forKey: .intro)
        self.outro = try c.decodeIfPresent(String.self, forKey: .outro)
        self.bgm = try c.decodeIfPresent(BGMConfig.self, forKey: .bgm)
        // Backward-compatible defaults so older episode.json files load.
        self.introOffsetSec = (try? c.decodeIfPresent(Double.self, forKey: .introOffsetSec)) ?? 2.0
        self.outroOffsetSec = (try? c.decodeIfPresent(Double.self, forKey: .outroOffsetSec)) ?? 5.0
        self.duckingGainDB = (try? c.decodeIfPresent(Double.self, forKey: .duckingGainDB)) ?? -12
        self.duckingFadeSec = (try? c.decodeIfPresent(Double.self, forKey: .duckingFadeSec)) ?? 0.5
    }
}

public struct BGMConfig: Codable, Sendable, Equatable {
    public var file: String
    public var duck: Double

    public init(file: String, duck: Double = -12) {
        self.file = file
        self.duck = duck
    }
}

// MARK: - Show

public struct Show: Codable, Sendable, Equatable {
    public var name: String
    public var uuid: UUID
    public var assets: ShowAssets

    public init(name: String, uuid: UUID = UUID(), assets: ShowAssets = ShowAssets()) {
        self.name = name
        self.uuid = uuid
        self.assets = assets
    }
}

public struct ShowAssets: Codable, Sendable, Equatable {
    public var intro: String?
    public var outro: String?
    public var bgm: String?

    public init(intro: String? = nil, outro: String? = nil, bgm: String? = nil) {
        self.intro = intro
        self.outro = outro
        self.bgm = bgm
    }
}

// MARK: - Sidecars

/// Sidecar that records the parameters used to produce a given generation file.
public struct OperationParamsRecord: Codable, Sendable, Equatable {
    public var op: String
    public var input: String?
    public var createdAt: Date
    public var params: JSONValue?

    public init(op: String, input: String?, createdAt: Date = Date(), params: JSONValue? = nil) {
        self.op = op
        self.input = input
        self.createdAt = createdAt
        self.params = params
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment] = []) {
        self.segments = segments
    }
}

public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
