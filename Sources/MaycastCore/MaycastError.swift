import Foundation

public enum MaycastError: Error, CustomStringConvertible, Sendable {
    case bundleAlreadyExists(URL)
    case bundleNotFound(URL)
    case manifestNotFound(URL)
    case invalidBundleStructure(URL, reason: String)
    case sourceFileNotFound(URL)
    case trackNotFound(id: String)
    case chapterNotFound(id: String)
    case generationOutOfRange(track: String, generation: Int, max: Int)
    case showNotConfigured(reason: String)
    case ioError(URL, underlying: Error)
    case decodingFailed(URL, underlying: Error)
    case encodingFailed(URL, underlying: Error)
    case audioReadFailed(URL, underlying: Error)
    case audioWriteFailed(URL, underlying: Error)
    case audioFormatMismatch(expected: String, actual: String)
    case externalToolNotFound(tool: String, hint: String)
    case externalToolFailed(tool: String, code: Int32, message: String)
    /// A requested operation can't proceed (e.g. exporting an episode with no
    /// tracks). The string is a human-readable reason.
    case invalidOperation(String)

    public var description: String {
        switch self {
        case .bundleAlreadyExists(let url):
            return "Bundle already exists at \(url.path)"
        case .bundleNotFound(let url):
            return "Bundle not found at \(url.path)"
        case .manifestNotFound(let url):
            return "Manifest not found at \(url.path)"
        case .invalidBundleStructure(let url, let reason):
            return "Invalid bundle at \(url.path): \(reason)"
        case .sourceFileNotFound(let url):
            return "Source file not found at \(url.path)"
        case .trackNotFound(let id):
            return "Track not found: \(id)"
        case .chapterNotFound(let id):
            return "Chapter not found: \(id)"
        case .generationOutOfRange(let track, let generation, let max):
            return "Generation \(generation) is out of range for track '\(track)' (max: \(max))"
        case .showNotConfigured(let reason):
            return "Show not configured: \(reason)"
        case .ioError(let url, let underlying):
            return "I/O error at \(url.path): \(underlying)"
        case .decodingFailed(let url, let underlying):
            return "Failed to decode \(url.path): \(underlying)"
        case .encodingFailed(let url, let underlying):
            return "Failed to encode \(url.path): \(underlying)"
        case .audioReadFailed(let url, let underlying):
            return "Failed to read audio at \(url.path): \(underlying)"
        case .audioWriteFailed(let url, let underlying):
            return "Failed to write audio at \(url.path): \(underlying)"
        case .audioFormatMismatch(let expected, let actual):
            return "Audio format mismatch — expected \(expected), got \(actual)"
        case .externalToolNotFound(let tool, let hint):
            return "\(tool) not found. \(hint)"
        case .externalToolFailed(let tool, let code, let message):
            return "\(tool) failed (exit \(code)): \(message)"
        case .invalidOperation(let reason):
            return reason
        }
    }
}
