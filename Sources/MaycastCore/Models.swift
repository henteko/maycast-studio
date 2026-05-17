import Foundation

// MARK: - Episode

public struct Episode: Codable, Sendable, Equatable {
    public var id: String
    public var uuid: UUID
    public var show: String?
    public var tracks: [Track]
    public var mix: MixConfig

    public init(
        id: String,
        uuid: UUID = UUID(),
        show: String? = nil,
        tracks: [Track] = [],
        mix: MixConfig = MixConfig()
    ) {
        self.id = id
        self.uuid = uuid
        self.show = show
        self.tracks = tracks
        self.mix = mix
    }
}

public struct Track: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: String
    public var current: String
    public var history: [String]

    public init(id: String, source: String, current: String, history: [String]) {
        self.id = id
        self.source = source
        self.current = current
        self.history = history
    }
}

public struct MixConfig: Codable, Sendable, Equatable {
    public var intro: String?
    public var outro: String?
    public var bgm: BGMConfig?

    public init(intro: String? = nil, outro: String? = nil, bgm: BGMConfig? = nil) {
        self.intro = intro
        self.outro = outro
        self.bgm = bgm
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
