import Foundation

/// Polish is delegated to an external cleanup service. Each service lives in
/// its own module (`Auphonic/` + `AuphonicPolishEngine`, `Cleanvoice/` +
/// `CleanvoicePolishEngine`) behind the `PolishEngine` protocol, so the GUI
/// only picks a provider and renders progress; uploading, processing,
/// downloading and writing generations are the engine's job.
public enum PolishProvider: String, CaseIterable, Codable, Sendable {
    case auphonic
    case cleanvoice

    public var displayName: String {
        switch self {
        case .auphonic: return "Auphonic"
        case .cleanvoice: return "Cleanvoice"
        }
    }
}

/// One speaker track handed to an engine: the track ID and its current audio.
public struct PolishSpeaker: Sendable, Equatable {
    public var id: String
    public var fileURL: URL

    public init(id: String, fileURL: URL) {
        self.id = id
        self.fileURL = fileURL
    }
}

/// Progress reported while an engine runs. `uploading` / `downloading` carry
/// per-track progress (0.0–1.0); `processing` carries the service's
/// human-readable stage (e.g. "Audio Algorithms", "EDITING").
public enum PolishProgress: Sendable, Equatable {
    case uploading([String: Double])
    case processing(String)
    case downloading([String: Double])
}

/// Per-track outcome of a polish run: the new generation's relative path.
public struct PolishTrackOutput: Sendable, Equatable {
    public var trackID: String
    public var generationPath: String

    public init(trackID: String, generationPath: String) {
        self.trackID = trackID
        self.generationPath = generationPath
    }
}

/// A cleanup service that turns every speaker's current audio into one new
/// `polish` generation per track (one shared undo batch).
public protocol PolishEngine: Sendable {
    var provider: PolishProvider { get }

    func run(
        bundleURL: URL,
        speakers: [PolishSpeaker],
        onProgress: @Sendable @escaping (PolishProgress) -> Void
    ) async throws -> [PolishTrackOutput]
}
